defmodule SiteMaps.ConfigSourcesTest do
  use ExUnit.Case, async: false

  defmodule UseOnly do
    use SiteMaps, url: "https://one.test/sitemap.xml", adapter: SiteMaps.Adapters.Noop, max_links: 10
    process :static
    @impl SiteMaps
    def urls(:static, _args, _ctx), do: [url("/")]
  end

  defmodule FromApp do
    use SiteMaps, otp_app: :site_maps, adapter: SiteMaps.Adapters.Noop, max_links: 10
    process :static
    @impl SiteMaps
    def urls(:static, _args, _ctx), do: [url("/")]
  end

  defmodule AllSources do
    use SiteMaps, otp_app: :site_maps, adapter: SiteMaps.Adapters.Noop, url: "https://use.test/sitemap.xml"
    process :static
    @impl SiteMaps
    def config(%{gzip: true}), do: [url: "https://callback.test/sitemap.xml.gz"]
    def config(_ctx), do: []
    @impl SiteMaps
    def urls(:static, _args, _ctx), do: [url("/")]
  end

  defmodule Evaluated do
    use SiteMaps,
      url: System.get_env("SITE_MAPS_TEST_URL", "https://compiled.test/sitemap.xml"),
      adapter: {SiteMaps.Adapters.FileSystem, directory: Path.expand("priv/sitemaps")}

    process :static
    @impl SiteMaps
    def urls(:static, _args, _ctx), do: [url("/")]
  end

  defmodule Evaluated do
    use SiteMaps,
      url: System.get_env("SITE_MAPS_TEST_URL", "https://compiled.test/sitemap.xml"),
      adapter: {SiteMaps.Adapters.FileSystem, directory: Path.expand("priv/sitemaps")}

    process :static
    @impl SiteMaps
    def urls(:static, _args, _ctx), do: [url("/")]
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:site_maps, FromApp)
      Application.delete_env(:site_maps, AllSources)
    end)
  end

  test "options given to use SiteMaps are enough, no config/1 needed" do
    config = SiteMaps.config!(UseOnly, %{})

    assert config.url == "https://one.test/sitemap.xml"
    assert config.max_links == 10
    assert {:ok, %{index: "https://one.test/sitemap.xml", links: 1}} = SiteMaps.generate(UseOnly)
  end

  test "reads the application environment at runtime and lets it override use options" do
    Application.put_env(:site_maps, FromApp, url: "https://app.test/sitemap.xml", max_links: 20)

    assert %{url: "https://app.test/sitemap.xml", max_links: 20} = SiteMaps.config!(FromApp, %{})
  end

  test "config/1 wins over the application environment, which wins over use options" do
    Application.put_env(:site_maps, AllSources, url: "https://app.test/sitemap.xml")

    assert SiteMaps.config!(AllSources, %{}).url == "https://app.test/sitemap.xml"
    assert SiteMaps.config!(AllSources, %{gzip: true}).url == "https://callback.test/sitemap.xml.gz"
  end

  test "a missing url names the module and where to set it" do
    message = ~r/FromApp has no :url option.*config :site_maps, SiteMaps.ConfigSourcesTest.FromApp, url:/
    assert_raise ArgumentError, message, fn -> SiteMaps.config!(FromApp, %{}) end
  end

  test "use options are evaluated once, at compile time" do
    System.put_env("SITE_MAPS_TEST_URL", "https://runtime.test/sitemap.xml")
    on_exit(fn -> System.delete_env("SITE_MAPS_TEST_URL") end)

    config = SiteMaps.config!(Evaluated, %{})
    assert config.url == "https://compiled.test/sitemap.xml"
    assert config.adapter == {SiteMaps.Adapters.FileSystem, [directory: Path.expand("priv/sitemaps")]}
  end
end
