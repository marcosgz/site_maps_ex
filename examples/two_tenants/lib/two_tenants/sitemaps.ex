defmodule TwoTenants.Sitemaps do
  @moduledoc "Sitemaps of every tenant, written under `priv/sitemaps/<tenant>`."

  use SiteMaps

  alias TwoTenants.Tenants

  @impl SiteMaps
  def config(%{tenant: tenant}) do
    [
      url: Tenants.base_url(tenant) <> "/sitemap.xml",
      adapter: {SiteMaps.Adapters.FileSystem, directory: Path.join(sitemaps_dir(), tenant.slug)},
      xsl_stylesheet_url: "/_sitemap-stylesheet.xsl",
      xsl_index_stylesheet_url: "/_sitemap-index-stylesheet.xsl"
    ]
  end

  process :static

  process :posts, "posts/%{year}-%{month}/sitemap.xml",
    args: [year: :integer, month: :integer],
    defaults: [year: &__MODULE__.this_year/0, month: &__MODULE__.this_month/0]

  process :news, "news/sitemap.xml"

  @impl SiteMaps
  def urls(:static, _args, _context),
    do: [url("/", changefreq: :daily, priority: 1.0), url("/about")]

  def urls(:posts, %{year: year, month: month}, %{tenant: tenant}) do
    tenant
    |> Tenants.posts(year, month)
    |> Stream.map(&url("/posts/#{&1.slug}", lastmod: &1.updated_at))
  end

  def urls(:news, _args, %{tenant: tenant}) do
    for post <- Tenants.latest(tenant) do
      url("/posts/#{post.slug}",
        lastmod: post.updated_at,
        news: [
          publication_name: tenant.name,
          publication_language: "en",
          title: post.title,
          publication_date: post.updated_at
        ]
      )
    end
  end

  @impl SiteMaps
  def load_context(%{"tenant" => slug}), do: %{tenant: Tenants.fetch!(slug)}

  def this_year, do: Date.utc_today().year
  def this_month, do: Date.utc_today().month

  @doc "Generates every month of the current year for `tenant`, pruning stale files."
  def backfill(tenant) do
    months = for month <- 1..this_month(), do: {:posts, [year: this_year(), month: month]}

    SiteMaps.generate(__MODULE__,
      context: %{tenant: tenant},
      only: [:static, :news | months],
      prune: true
    )
  end

  defp sitemaps_dir, do: Application.fetch_env!(:two_tenants, :sitemaps_dir)
end
