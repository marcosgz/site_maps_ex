defmodule TwoTenantsWeb.Plugs.Tenant do
  @moduledoc "Resolves the tenant from the host; unknown hosts get a 404."

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case TwoTenants.Tenants.by_host(conn.host) do
      nil -> conn |> send_resp(404, "Not Found") |> halt()
      tenant -> assign(conn, :tenant, tenant)
    end
  end

  @doc "The sitemaps of the requested host, for `SiteMaps.Plug`."
  def sitemaps(conn) do
    if tenant = TwoTenants.Tenants.by_host(conn.host),
      do: {TwoTenants.Sitemaps, %{tenant: tenant}}
  end
end
