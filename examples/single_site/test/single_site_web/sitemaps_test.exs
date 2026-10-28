defmodule SingleSiteWeb.SitemapsTest do
  use SingleSiteWeb.ConnCase, async: false

  alias SingleSite.Sitemaps

  setup_all do
    {:ok, config} = Application.fetch_env(:single_site, Sitemaps)
    {_adapter, adapter_opts} = config[:adapter]
    File.rm_rf!(adapter_opts[:directory])
    {:ok, _} = Sitemaps.backfill()
    :ok
  end

  defp shard(month), do: "posts/#{Sitemaps.this_year()}-#{month}/sitemap1.xml"

  test "serves the index listing the static sitemap and every monthly shard", %{conn: conn} do
    index = conn |> get("/sitemap.xml") |> response(200)

    assert index =~ "<sitemapindex"
    assert index =~ "http://localhost:4000/sitemap_static1.xml"

    for month <- 1..Sitemaps.this_month() do
      assert index =~ "http://localhost:4000/#{shard(month)}"
    end
  end

  test "serves a monthly shard", %{conn: conn} do
    conn = get(conn, "/" <> shard(1))

    assert response_content_type(conn, :xml) =~ "application/xml"

    assert response(conn, 200) =~
             "<loc>http://localhost:4000/posts/#{Sitemaps.this_year()}-1-story-1</loc>"
  end

  test "robots.txt points to the sitemap", %{conn: conn} do
    robots = conn |> get("/robots.txt") |> response(200)

    assert robots =~ "Sitemap: http://localhost:4000/sitemap.xml"
    assert robots =~ "Disallow: /admin"
  end

  test "serves the XSL stylesheets referenced by the sitemaps", %{conn: conn} do
    assert conn |> get("/_sitemap-index-stylesheet.xsl") |> response(200) =~ "xsl:stylesheet"
  end

  test "missing shards are not served", %{conn: conn} do
    assert conn |> get("/posts/1999-1/sitemap1.xml") |> response(404)
  end

  test "regenerating one month keeps the rest of the index", %{conn: conn} do
    assert {:ok, _} =
             SiteMaps.generate(Sitemaps, only: [posts: [year: Sitemaps.this_year(), month: 1]])

    index = conn |> get("/sitemap.xml") |> response(200)
    assert index =~ shard(1)
    assert index =~ shard(Sitemaps.this_month())
    assert index =~ "sitemap_static1.xml"
  end
end
