defmodule TwoTenantsWeb.SiteController do
  use TwoTenantsWeb, :controller

  def home(conn, _params), do: text(conn, conn.assigns.tenant.name)

  def post(conn, %{"slug" => slug}), do: text(conn, "#{conn.assigns.tenant.name}: #{slug}")

  def robots(conn, _params) do
    config = SiteMaps.config!(TwoTenants.Sitemaps, %{tenant: conn.assigns.tenant})
    text(conn, SiteMaps.RobotsTxt.render(sitemaps: config, extra: ["Disallow: /admin"]))
  end
end
