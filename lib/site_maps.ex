defmodule SiteMaps do
  @moduledoc """
  Sitemap generation: streaming, parallel and incremental.

      defmodule MyApp.Sitemaps do
        use SiteMaps, otp_app: :my_app, adapter: {SiteMaps.Adapters.FileSystem, directory: "priv/sitemaps"}

        process :static
        process :posts, "posts/%{year}-%{month}/sitemap.xml",
          args: [year: :integer, month: :integer],
          defaults: [year: &MyApp.Clock.year/0, month: &MyApp.Clock.month/0]

        @impl SiteMaps
        def urls(:static, _args, _context), do: [url("/", priority: 1.0)]

        def urls(:posts, %{year: year, month: month}, _context) do
          MyApp.Posts.stream(year, month) |> Stream.map(&url("/posts/\#{&1.slug}", lastmod: &1.updated_at))
        end
      end

      # config/runtime.exs
      config :my_app, MyApp.Sitemaps, url: "https://example.com/sitemap.xml.gz"

      SiteMaps.generate(MyApp.Sitemaps)
      SiteMaps.generate(MyApp.Sitemaps, only: [posts: [year: 2026, month: 3]])

  Every process returns an `Enumerable` of `SiteMaps.URL` entries, consumed lazily and written to
  files that rotate at the sitemap protocol limits. Processes run in parallel, and runs that only
  regenerate some processes keep the other entries of the existing index.

  For several sites in one app, pass a `:context` identifying the site to `generate/2` and
  implement `c:config/1` to build each site's options from it. See
  [multitenancy_phoenix](https://github.com/marcosgz/multitenancy_phoenix) for host→site→theme
  Phoenix apps.
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

  @optional_callbacks config: 1, external_sitemaps: 1, url_filter: 2, load_context: 1

  @doc """
  Defines a sitemap module.

  Configuration options (see `SiteMaps.Config`) can be given here, read from the application
  environment with `:otp_app`, and returned by `c:config/1`. They are merged in that order, so
  later sources win:

      use SiteMaps, otp_app: :my_app, adapter: {SiteMaps.Adapters.FileSystem, directory: "priv/sitemaps"}

      # config/runtime.exs
      config :my_app, MyApp.Sitemaps, url: "https://example.com/sitemap.xml"

  `c:config/1` is only needed when options depend on the context, e.g. one sitemap per site.
  """
  defmacro __using__(opts) do
    {otp_app, config} = Keyword.pop(opts, :otp_app)

    quote do
      @behaviour SiteMaps
      import SiteMaps, only: [process: 1, process: 2, process: 3, url: 1, url: 2]
      Module.register_attribute(__MODULE__, :site_maps_processes, accumulate: true)
      @site_maps_otp_app unquote(otp_app)
      @site_maps_config unquote(config)
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
    validate_names!(env, Enum.map(declared, &elem(&1, 0)))
    validate_locations!(env, declared)
    processes = Enum.map(declared, &process_ast/1)

    config = env.module |> Module.get_attribute(:site_maps_config) |> Macro.escape()

    quote do
      @doc false
      def __site_maps__(:processes), do: unquote(processes)

      def __site_maps__(:otp_app), do: @site_maps_otp_app

      def __site_maps__(:config) do
        base = unquote(config)

        if @site_maps_otp_app,
          do: Keyword.merge(base, Application.get_env(@site_maps_otp_app, __MODULE__, [])),
          else: base
      end
    end
  end

  defp validate_names!(env, []) do
    raise CompileError, file: env.file, description: "#{inspect(env.module)} declares no sitemap process"
  end

  defp validate_names!(env, names) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> raise CompileError, file: env.file, description: "sitemap process #{inspect(dup)} is declared twice"
    end
  end

  defp process_ast({name, location, opts}) do
    quote do
      %SiteMaps.Process{
        name: unquote(name),
        location: unquote(location),
        args: unquote(opts[:args] || []),
        defaults: unquote(opts[:defaults] || [])
      }
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

  @doc """
  Builds the validated configuration of `module` for `context`: the `use SiteMaps` options, then
  the application environment (`:otp_app`), then `c:config/1` when the module defines it.
  """
  @spec config!(module, map) :: Config.t()
  def config!(module, context) do
    opts =
      module.__site_maps__(:config)
      |> Keyword.merge(if function_exported?(module, :config, 1), do: module.config(context), else: [])

    for key <- [:url, :adapter], not Keyword.has_key?(opts, key) do
      raise ArgumentError,
            "#{inspect(module)} has no #{inspect(key)} option: give it to `use SiteMaps`, set it with " <>
              "`config #{inspect(module.__site_maps__(:otp_app) || :my_app)}, #{inspect(module)}, #{key}: ...` " <>
              "(requires `use SiteMaps, otp_app: ...`) or return it from config/1"
    end

    Config.new!(opts)
  end

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
