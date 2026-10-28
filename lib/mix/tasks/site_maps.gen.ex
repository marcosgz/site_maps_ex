defmodule Mix.Tasks.SiteMaps.Gen do
  @shortdoc "Generates a starter SiteMaps module"

  @moduledoc """
  Generates a starter module that uses `SiteMaps`, with a static process and a dynamic process
  sharded by month, written through the `SiteMaps.Adapters.FileSystem` adapter.

      $ mix site_maps.gen MyApp.Sitemaps
      $ mix site_maps.gen MyApp.Sitemaps --multi

  The module is written to `lib/my_app/sitemaps.ex`. By default it reads its `url` from the
  application environment and the task prints the configuration to add; with `--multi` the url and
  adapter come from `config/1`.

  ## Options

    * `--multi` - generate a module for several sites, with `c:SiteMaps.config/1` and
      `c:SiteMaps.load_context/1` building the options of each site from the context
    * `--force` - overwrite an existing file without asking
  """

  use Mix.Task

  import Mix.Generator

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: [force: :boolean, multi: :boolean]) do
      {opts, [name], []} -> generate(name, opts)
      _ -> Mix.raise("expected a module name, e.g. mix site_maps.gen MyApp.Sitemaps")
    end
  end

  defp generate(name, opts) do
    unless name =~ ~r/^[A-Z]\w*(\.[A-Z]\w*)*$/, do: Mix.raise("expected a module name, got: #{inspect(name)}")

    app =
      Mix.Project.config()[:app] ||
        Mix.raise("mix site_maps.gen must run inside an application (in an umbrella, from apps/<app>)")

    multi? = Keyword.get(opts, :multi, false)
    target = Path.join("lib", Macro.underscore(name) <> ".ex")
    assigns = [module: name, app: app, multi?: multi?]

    if create_file(target, sitemaps_template(assigns), force: Keyword.get(opts, :force, false)) do
      Mix.shell().info(next_steps(assigns))
    end
  end

  defp next_steps(assigns) do
    if assigns[:multi?] do
      """

      Generate the sitemaps of a site with:

          $ mix site_maps.generate #{assigns[:module]} --context site=example.com

      Serve them with a plug resolving the site from the host, see `SiteMaps.Plug`.
      """
    else
      """

      Add the public URL of the sitemap index to config/runtime.exs:

          config #{inspect(assigns[:app])}, #{assigns[:module]}, url: "https://example.com/sitemap.xml.gz"

      Generate the sitemaps with:

          $ mix site_maps.generate #{assigns[:module]}

      Serve them from the endpoint, before the router:

          plug SiteMaps.Plug, sitemaps: {#{assigns[:module]}, %{}}
      """
    end
  end

  embed_template(:sitemaps, ~S"""
  defmodule <%= @module %> do
    @moduledoc "Sitemaps of the application."

  <%= if @multi? do %>  use SiteMaps, otp_app: <%= inspect(@app) %>

    @impl SiteMaps
    def config(%{site: host}) do
      [
        url: "https://#{host}/sitemap.xml.gz",
        adapter: {SiteMaps.Adapters.FileSystem, directory: Path.join("priv/sitemaps", host)}
      ]
    end

    @impl SiteMaps
    def load_context(%{"site" => host}), do: %{site: host}
  <% else %>  use SiteMaps,
      otp_app: <%= inspect(@app) %>,
      adapter: {SiteMaps.Adapters.FileSystem, directory: "priv/sitemaps"}
  <% end %>
    # Other storages:
    #   NFS/EFS mount: {SiteMaps.Adapters.FileSystem, directory: "/mnt/nfs/sitemaps"}
    #   AWS S3 or S3-compatible: {SiteMaps.Adapters.S3, bucket: "my-bucket", prefix: "sitemaps", region: "us-east-1"}
    #   Cloudflare R2: {SiteMaps.Adapters.R2, account_id: "my-account-id", bucket: "my-bucket", prefix: "sitemaps"}

    process :static

    process :archive, "archive/%{month}/sitemap.xml",
      args: [month: :string],
      defaults: [month: &__MODULE__.current_month/0]

    @impl SiteMaps
    def urls(:static, _args, _context) do
      [url("/", changefreq: :daily, priority: 1.0), url("/about")]
    end

    def urls(:archive, %{month: month}, _context) do
      first = Date.from_iso8601!(month <> "-01")
      last = Enum.min([Date.end_of_month(first), Date.utc_today()], Date)

      # Replace with a stream over your records, e.g. Repo.stream/1 inside a transaction.
      first
      |> Date.range(last, 1)
      |> Stream.map(&url("/archive/#{&1}", lastmod: &1))
    end

    def current_month, do: Calendar.strftime(Date.utc_today(), "%Y-%m")
  end
  """)
end
