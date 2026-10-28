defmodule SiteMaps do
  @moduledoc """
  Sitemap generation: streaming, parallel, incremental and multi-tenant.

      defmodule MyApp.Sitemaps do
        use SiteMaps

        @impl SiteMaps
        def config(%{site: site}) do
          [url: "https://\#{site.host}/sitemap.xml.gz", adapter: {SiteMaps.Adapters.FileSystem, directory: "priv/sitemaps/\#{site.slug}"}]
        end

        process :static
        process :posts, "posts/%{year}-%{month}/sitemap.xml",
          args: [year: :integer, month: :integer],
          defaults: [year: &MyApp.Clock.year/0, month: &MyApp.Clock.month/0]

        @impl SiteMaps
        def urls(:static, _args, _context), do: [url("/", priority: 1.0)]

        def urls(:posts, %{year: year, month: month}, %{site: site}) do
          site |> MyApp.Posts.stream(year, month) |> Stream.map(&url("/posts/\#{&1.slug}", lastmod: &1.updated_at))
        end
      end

      SiteMaps.generate(MyApp.Sitemaps, context: %{site: site})
      SiteMaps.generate(MyApp.Sitemaps, context: %{site: site}, only: [posts: [year: 2026, month: 3]])

  Every process returns an `Enumerable` of `SiteMaps.URL` entries, consumed lazily and written to
  files that rotate at the sitemap protocol limits. Processes run in parallel, and runs that only
  regenerate some processes keep the other entries of the existing index.
  """

  alias SiteMaps.{Config, Process}

  @doc "Returns the configuration options for `context`. See `SiteMaps.Config`."
  @callback config(context :: map) :: keyword

  @doc "Returns the URLs of the process `name` executed with `args`."
  @callback urls(name :: atom, args :: map, context :: map) :: Enumerable.t()

  @doc "Sitemaps added to the index as they are, e.g. `[{\"https://cdn.example.com/legacy.xml\", ~D[2026-01-01]}]`."
  @callback external_sitemaps(context :: map) :: [{String.t(), DateTime.t() | Date.t() | nil} | String.t()]

  @doc "Drops (`nil`) or replaces every URL before it is written."
  @callback url_filter(SiteMaps.URL.t(), context :: map) :: SiteMaps.URL.t() | nil

  @doc "Builds the context from its serialized form (mix task and Oban arguments)."
  @callback load_context(map) :: map

  @optional_callbacks external_sitemaps: 1, url_filter: 2, load_context: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour SiteMaps
      import SiteMaps, only: [process: 1, process: 2, process: 3, url: 1, url: 2]
      Module.register_attribute(__MODULE__, :site_maps_processes, accumulate: true)
      @before_compile SiteMaps
    end
  end

  @doc """
  Declares a process.

      process :static
      process :news, "sitemap_news.xml"
      process :posts, "posts/%{year}/sitemap.xml", args: [year: :integer], defaults: [year: 2026]

  The location is relative to the index directory and must interpolate every argument (`%{arg}`),
  so each execution writes its own files. Without location, files are written next to the index as
  `sitemap_<name>1.xml`, ... Two processes cannot share a location. Argument types are `:integer`, `:string`, `:date`, `:boolean` and
  `:atom`; string values (from the CLI or job arguments) are cast. Defaults may be values or 0-arity
  functions evaluated when the process is enqueued.
  """
  defmacro process(name, location \\ nil, opts \\ []) do
    {location, opts} = if is_list(location), do: {nil, location}, else: {location, opts}
    quote do: @site_maps_processes({unquote(name), unquote(location), unquote(Macro.escape(opts))})
  end

  @doc "Builds a `SiteMaps.URL`. Paths are resolved against the site origin."
  @spec url(String.t(), keyword) :: SiteMaps.URL.t()
  def url(loc, opts \\ []), do: SiteMaps.URL.new(loc, opts)

  @doc false
  defmacro __before_compile__(env) do
    declared = env.module |> Module.get_attribute(:site_maps_processes) |> Enum.reverse()
    names = Enum.map(declared, &elem(&1, 0))

    if names == [] do
      raise CompileError, file: env.file, description: "#{inspect(env.module)} declares no sitemap process"
    end

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> raise CompileError, file: env.file, description: "sitemap process #{inspect(dup)} is declared twice"
    end

    validate_locations!(env, declared)

    processes =
      for {name, location, opts} <- declared do
        quote do
          %SiteMaps.Process{
            name: unquote(name),
            location: unquote(location),
            args: unquote(opts[:args] || []),
            defaults: unquote(opts[:defaults] || [])
          }
        end
      end

    quote do
      @doc false
      def __site_maps__(:processes), do: unquote(processes)
    end
  end

  defp validate_locations!(env, declared) do
    templates =
      for {name, location, opts} <- declared, is_nil(location) or is_binary(location) do
        args = Keyword.keys(opts[:args] || [])
        missing = Enum.reject(args, &(is_binary(location) and String.contains?(location, "%{#{&1}}")))

        if missing != [] do
          raise CompileError,
            file: env.file,
            description:
              "the location of sitemap process #{inspect(name)} must interpolate every argument, missing: " <>
                Enum.map_join(missing, ", ", &"%{#{&1}}")
        end

        {name, SiteMaps.Location.template(%Process{name: name, location: location})}
      end

    templates
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.find(fn {_template, names} -> length(names) > 1 end)
    |> case do
      nil ->
        :ok

      {template, names} ->
        raise CompileError,
          file: env.file,
          description: "sitemap processes #{inspect(names)} write to the same location #{inspect(template)}"
    end
  end

  @doc "Declared processes of `module`."
  @spec processes(module) :: [Process.t()]
  def processes(module), do: module.__site_maps__(:processes)

  @doc "Builds the validated configuration of `module` for `context`."
  @spec config!(module, map) :: Config.t()
  def config!(module, context), do: context |> module.config() |> Config.new!()

  @doc """
  Generates the sitemaps of `module`.

  ## Options

    * `:context` - map passed to every callback (default `%{}`)
    * `:only` - processes to run, e.g. `[:static, posts: [year: 2026, month: 3]]`. By default every
      process runs once with its default arguments.
    * `:prune` - delete files of the regenerated processes that are no longer listed (default `false`)
    * `:max_concurrency` - overrides the configured concurrency
  """
  @spec generate(module, keyword) :: {:ok, SiteMaps.Result.t()} | {:error, term}
  defdelegate generate(module, opts \\ []), to: SiteMaps.Runner, as: :run

  @doc "Same as `generate/2` but raises on errors."
  @spec generate!(module, keyword) :: SiteMaps.Result.t()
  def generate!(module, opts \\ []) do
    case generate(module, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise SiteMaps.Error, reason: reason
    end
  end
end

defmodule SiteMaps.Error do
  @moduledoc "Raised by `SiteMaps.generate!/2` when generation fails."

  defexception [:reason]

  @impl true
  def message(%{reason: {:process_failed, name, args, kind, error, _stack}}) do
    "sitemap process #{inspect(name)} #{inspect(args)} failed: " <> Exception.format_banner(kind, error)
  end

  def message(%{reason: reason}), do: "sitemap generation failed: #{inspect(reason)}"
end

defmodule SiteMaps.EntryTooLargeError do
  @moduledoc "A single sitemap entry is larger than the configured `max_bytes` of a file."

  defexception [:loc, :bytes, :max_bytes]

  @impl true
  def message(%{loc: loc, bytes: bytes, max_bytes: max}) do
    "the sitemap entry #{loc} takes #{bytes} bytes and does not fit a sitemap file of #{max} bytes"
  end
end

defmodule SiteMaps.Result do
  @moduledoc "Outcome of `SiteMaps.generate/2`."

  defstruct index: nil, files: [], links: 0, news: 0, pruned: []

  @type t :: %__MODULE__{
          index: String.t() | nil,
          files: [SiteMaps.IndexEntry.t()],
          links: non_neg_integer,
          news: non_neg_integer,
          pruned: [String.t()]
        }
end
