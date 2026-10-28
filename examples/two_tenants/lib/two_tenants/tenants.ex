defmodule TwoTenants.Tenants do
  @moduledoc "The two tenants of the example and their fake content."

  @tenants [
    %{slug: "acme", name: "Acme Daily", host: "acme.localtest.me"},
    %{slug: "globex", name: "Globex Times", host: "globex.localtest.me"}
  ]

  def all, do: @tenants

  def fetch!(slug),
    do: Enum.find(@tenants, &(&1.slug == slug)) || raise(ArgumentError, "unknown tenant #{slug}")

  def by_host(host), do: Enum.find(@tenants, &(&1.host == host))

  def base_url(tenant),
    do: "http://#{tenant.host}:#{Application.fetch_env!(:two_tenants, :public_port)}"

  @doc "Deterministic posts published by `tenant` in a month, none in the future."
  def posts(tenant, year, month) do
    first = Date.new!(year, month, 1)

    if Date.compare(first, Date.utc_today()) == :gt do
      []
    else
      count = rem(:erlang.phash2({tenant.slug, year, month}), 15) + 3

      for n <- 1..count do
        day = min(n, Date.days_in_month(first))

        %{
          slug: "#{year}-#{month}-#{tenant.slug}-story-#{n}",
          title: "#{tenant.name} story #{n} of #{year}-#{month}",
          updated_at: DateTime.new!(Date.new!(year, month, day), ~T[12:00:00], "Etc/UTC")
        }
      end
    end
  end

  def latest(tenant) do
    today = Date.utc_today()
    tenant |> posts(today.year, today.month) |> Enum.take(-3)
  end
end
