defmodule SingleSite.Sitemaps do
  @moduledoc """
  The sitemaps of the site. The URL comes from `config :single_site, SingleSite.Sitemaps`, so
  no `config/1` callback or context is needed.
  """

  use SiteMaps,
    otp_app: :single_site,
    adapter: {SiteMaps.Adapters.FileSystem, directory: "priv/sitemaps"},
    xsl_stylesheet_url: "/_sitemap-stylesheet.xsl",
    xsl_index_stylesheet_url: "/_sitemap-index-stylesheet.xsl"

  alias SingleSite.Blog

  process :static

  process :posts, "posts/%{year}-%{month}/sitemap.xml",
    args: [year: :integer, month: :integer],
    defaults: [year: &__MODULE__.this_year/0, month: &__MODULE__.this_month/0]

  @impl SiteMaps
  def urls(:static, _args, _context),
    do: [url("/", changefreq: :daily, priority: 1.0), url("/about")]

  def urls(:posts, %{year: year, month: month}, _context) do
    year
    |> Blog.posts(month)
    |> Stream.map(&url("/posts/#{&1.slug}", lastmod: &1.updated_at))
  end

  def this_year, do: Date.utc_today().year
  def this_month, do: Date.utc_today().month

  @doc "Generates every month of the current year, pruning stale files."
  def backfill do
    months = for month <- 1..this_month(), do: {:posts, [year: this_year(), month: month]}
    SiteMaps.generate(__MODULE__, only: [:static | months], prune: true)
  end
end
