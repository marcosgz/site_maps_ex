defmodule SingleSiteWeb.SiteController do
  use SingleSiteWeb, :controller

  def home(conn, _params), do: text(conn, "Single Site")

  def post(conn, %{"slug" => slug}), do: text(conn, slug)

  def robots(conn, _params) do
    config = SiteMaps.config!(SingleSite.Sitemaps, %{})
    text(conn, SiteMaps.RobotsTxt.render(sitemaps: config, extra: ["Disallow: /admin"]))
  end
end
