defmodule Mix.Tasks.SiteMaps.Gen do
  @shortdoc "Generates a starter SiteMaps module"

  @moduledoc """
  Generates a starter module that uses `SiteMaps`, with a static process and a dynamic process
  sharded by month, written through the `SiteMaps.Adapters.FileSystem` adapter.

      $ mix site_maps.gen MyApp.Sitemaps

  The module is written to `lib/my_app/sitemaps.ex`.

  ## Options

    * `--force` - overwrite an existing file without asking
  """

  use Mix.Task

  import Mix.Generator

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: [force: :boolean]) do
      {opts, [name], []} -> generate(name, Keyword.get(opts, :force, false))
      _ -> Mix.raise("expected a module name, e.g. mix site_maps.gen MyApp.Sitemaps")
    end
  end

  defp generate(name, force) do
    unless name =~ ~r/^[A-Z]\w*(\.[A-Z]\w*)*$/, do: Mix.raise("expected a module name, got: #{inspect(name)}")

    target = Path.join("lib", Macro.underscore(name) <> ".ex")

    if create_file(target, sitemaps_template(module: name), force: force) do
      Mix.shell().info("""

      Generate the sitemaps with:

          $ mix site_maps.generate #{name}
      """)
    end
  end

  embed_template(:sitemaps, ~S"""
  defmodule <%= @module %> do
    @moduledoc "Sitemaps of the application."

    use SiteMaps

    @impl SiteMaps
    def config(_context) do
      [
        url: "https://example.com/sitemaps/sitemap.xml.gz",
        adapter: {SiteMaps.Adapters.FileSystem, directory: "priv/static/sitemaps"}
      ]
    end

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
