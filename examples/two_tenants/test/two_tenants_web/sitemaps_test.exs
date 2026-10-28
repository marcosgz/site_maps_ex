defmodule TwoTenantsWeb.SitemapsTest do
  use TwoTenantsWeb.ConnCase, async: false

  alias TwoTenants.{Sitemaps, Tenants}

  setup_all do
    File.rm_rf!(Application.fetch_env!(:two_tenants, :sitemaps_dir))
    for tenant <- Tenants.all(), do: {:ok, _} = Sitemaps.backfill(tenant)
    :ok
  end

  defp request(conn, host, path), do: get(%{conn | host: host}, path)

  test "each host serves its own sitemap index", %{conn: conn} do
    acme = conn |> request("acme.localtest.me", "/sitemap.xml") |> response(200)
    globex = conn |> request("globex.localtest.me", "/sitemap.xml") |> response(200)

    month = Date.utc_today().month
    assert acme =~ "<sitemapindex"
    assert acme =~ "http://acme.localtest.me:4000/posts/2026-#{month}/sitemap1.xml"
    assert acme =~ "http://acme.localtest.me:4000/news/sitemap1.xml"
    assert globex =~ "http://globex.localtest.me:4000/posts/2026-1/sitemap1.xml"
    refute acme =~ "globex"
    refute globex =~ "acme"
  end

  test "shards with the same path hold each tenant's own URLs", %{conn: conn} do
    acme = request(conn, "acme.localtest.me", "/posts/2026-1/sitemap1.xml")
    globex = conn |> request("globex.localtest.me", "/posts/2026-1/sitemap1.xml") |> response(200)

    assert response_content_type(acme, :xml) =~ "application/xml"

    assert response(acme, 200) =~
             "<loc>http://acme.localtest.me:4000/posts/2026-1-acme-story-1</loc>"

    assert globex =~ "globex-story-1"
    refute globex =~ "acme-story"
  end

  test "news sitemaps carry the tenant publication", %{conn: conn} do
    news = conn |> request("acme.localtest.me", "/news/sitemap1.xml") |> response(200)

    assert news =~ "<news:name>Acme Daily</news:name>"
  end

  test "robots.txt points to the host's sitemap", %{conn: conn} do
    robots = conn |> request("globex.localtest.me", "/robots.txt") |> response(200)

    assert robots =~ "Sitemap: http://globex.localtest.me:4000/sitemap.xml"
    assert robots =~ "Disallow: /admin"
  end

  test "serves the XSL stylesheets referenced by the sitemaps", %{conn: conn} do
    assert conn |> request("acme.localtest.me", "/_sitemap-index-stylesheet.xsl") |> response(200) =~
             "xsl:stylesheet"
  end

  test "unknown hosts and missing files are not served", %{conn: conn} do
    assert conn |> request("unknown.localtest.me", "/sitemap.xml") |> response(404)
    assert conn |> request("acme.localtest.me", "/posts/1999-1/sitemap1.xml") |> response(404)
  end

  test "regenerating one month keeps the rest of the index", %{conn: conn} do
    acme = Tenants.fetch!("acme")

    assert {:ok, _} =
             SiteMaps.generate(Sitemaps,
               context: %{tenant: acme},
               only: [posts: [year: 2026, month: 1]]
             )

    index = conn |> request("acme.localtest.me", "/sitemap.xml") |> response(200)
    assert index =~ "posts/2026-1/sitemap1.xml"
    assert index =~ "posts/2026-#{Date.utc_today().month}/sitemap1.xml"
    assert index =~ "news/sitemap1.xml"
  end
end
