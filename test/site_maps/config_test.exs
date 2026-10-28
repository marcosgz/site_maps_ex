defmodule SiteMaps.ConfigTest do
  use ExUnit.Case, async: true

  alias SiteMaps.Config

  defp config(opts \\ []) do
    Config.new!(
      Keyword.merge([url: "https://acme.test/sitemaps/acme/sitemap.xml.gz", adapter: SiteMaps.Adapters.Noop], opts)
    )
  end

  test "derives the root directory, index key and gzip from the URL" do
    config = config()

    assert URI.to_string(config.root_uri) == "https://acme.test/sitemaps/acme/"
    assert config.index_key == "sitemap.xml.gz"
    assert config.gzip?
    assert config.adapter == {SiteMaps.Adapters.Noop, []}
    refute config(url: "https://acme.test/sitemap.xml").gzip?
    assert URI.to_string(config(url: "https://acme.test/sitemap.xml").root_uri) == "https://acme.test/"
  end

  test "applies protocol defaults" do
    config = config()

    assert {config.max_links, config.max_bytes, config.max_news, config.max_index_links} ==
             {50_000, 50_000_000, 1_000, 50_000}

    assert config.max_concurrency == System.schedulers_online()
    assert config.default_changefreq == nil
    assert config.default_priority == nil
  end

  test "rejects limits above the protocol maximums" do
    assert_raise NimbleOptions.ValidationError, fn -> config(max_links: 50_001) end
    assert_raise NimbleOptions.ValidationError, fn -> config(max_bytes: 52_428_801) end
    assert_raise NimbleOptions.ValidationError, fn -> config(max_news: 1_001) end
    assert config(max_bytes: 52_428_800).max_bytes == 52_428_800
  end

  test "rejects invalid URLs and defaults" do
    assert_raise NimbleOptions.ValidationError, ~r/http\(s\)/, fn -> config(url: "/sitemap.xml") end
    assert_raise NimbleOptions.ValidationError, ~r/\.xml/, fn -> config(url: "https://acme.test/sitemap.txt") end
    assert_raise NimbleOptions.ValidationError, fn -> config(default_priority: 1.5) end
    assert_raise NimbleOptions.ValidationError, fn -> config(default_changefreq: :often) end
    assert config(default_priority: 1).default_priority == 1.0
  end

  test "maps keys to URLs and back" do
    config = config()
    url = Config.key_to_url(config, "posts/2026-03/sitemap1.xml.gz")

    assert url == "https://acme.test/sitemaps/acme/posts/2026-03/sitemap1.xml.gz"
    assert Config.url_to_key(config, url) == {:ok, "posts/2026-03/sitemap1.xml.gz"}
    assert Config.url_to_key(config, "https://acme.test/other/sitemap1.xml") == :error
    assert Config.url_to_key(config, "https://other.test/sitemaps/acme/sitemap1.xml") == :error
    assert Config.url_to_key(config, "http://acme.test/sitemaps/acme/sitemap1.xml") == :error
  end

  test "resolves paths against the site origin and keeps absolute URLs" do
    config = config()

    assert Config.resolve_loc(config, "/about") == "https://acme.test/about"
    assert Config.resolve_loc(config, "about?x=1") == "https://acme.test/about?x=1"
    assert Config.resolve_loc(config, "https://cdn.test/a") == "https://cdn.test/a"
    assert Config.resolve_loc(config(url: "http://localhost:4000/sitemap.xml"), "/a") == "http://localhost:4000/a"
  end
end
