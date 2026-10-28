defmodule SiteMaps.RobotsTxtTest do
  use ExUnit.Case, async: true

  alias SiteMaps.RobotsTxt

  test "renders one sitemap" do
    assert RobotsTxt.render(sitemaps: "https://acme.com/sitemap.xml.gz") ==
             "User-agent: *\nAllow: /\nSitemap: https://acme.com/sitemap.xml.gz\n"
  end

  test "renders several sitemaps and extra lines" do
    assert RobotsTxt.render(
             sitemaps: ["https://acme.com/sitemap.xml.gz", "https://cdn.acme.com/news.xml"],
             extra: ["Disallow: /admin", "Crawl-delay: 5"]
           ) ==
             """
             User-agent: *
             Allow: /
             Disallow: /admin
             Crawl-delay: 5
             Sitemap: https://acme.com/sitemap.xml.gz
             Sitemap: https://cdn.acme.com/news.xml
             """
  end

  test "accepts a configuration" do
    config = SiteMaps.Config.new!(url: "https://acme.com/sitemaps/sitemap.xml", adapter: SiteMaps.WebFixtures.Adapter)

    assert RobotsTxt.sitemap_directive(config) == "Sitemap: https://acme.com/sitemaps/sitemap.xml"
    assert RobotsTxt.render(sitemaps: [config]) =~ "Sitemap: https://acme.com/sitemaps/sitemap.xml\n"
  end

  test "requires sitemaps" do
    assert_raise KeyError, fn -> RobotsTxt.render(extra: []) end
    assert_raise FunctionClauseError, fn -> RobotsTxt.sitemap_directive("") end
  end

  test "rejects line breaks in sitemap URLs" do
    assert_raise ArgumentError, ~r/line breaks/, fn ->
      RobotsTxt.render(sitemaps: "https://a.com/s.xml\nDisallow: /")
    end

    assert_raise ArgumentError, fn -> RobotsTxt.sitemap_directive("https://a.com/s.xml\r") end
  end
end
