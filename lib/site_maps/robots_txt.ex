defmodule SiteMaps.RobotsTxt do
  @moduledoc """
  Renders a `robots.txt` pointing crawlers to the sitemaps.

      SiteMaps.RobotsTxt.render(sitemaps: "https://acme.com/sitemap.xml.gz", extra: ["Disallow: /admin"])
      #=> "User-agent: *\\nAllow: /\\nDisallow: /admin\\nSitemap: https://acme.com/sitemap.xml.gz\\n"

  A sitemap may be given as a URL or as a `SiteMaps.Config`, e.g. `SiteMaps.config!(MyApp.Sitemaps, ctx)`.
  """

  alias SiteMaps.Config

  @doc """
  Renders the `robots.txt` content.

  ## Options

    * `:sitemaps` - one sitemap or a list of them (required)
    * `:extra` - lines added after `Allow: /`, e.g. `["Disallow: /admin"]`
  """
  @spec render(keyword) :: String.t()
  def render(opts) do
    sitemaps = opts |> Keyword.fetch!(:sitemaps) |> List.wrap()
    lines = ["User-agent: *", "Allow: /"] ++ Keyword.get(opts, :extra, []) ++ Enum.map(sitemaps, &sitemap_directive/1)
    Enum.join(lines, "\n") <> "\n"
  end

  @doc "The `Sitemap:` directive of a sitemap URL or configuration."
  @spec sitemap_directive(String.t() | Config.t()) :: String.t()
  def sitemap_directive(%Config{url: url}), do: sitemap_directive(url)

  def sitemap_directive(url) when is_binary(url) and url != "" do
    if String.contains?(url, ["\r", "\n"]) do
      raise ArgumentError, "sitemap URL must not contain line breaks, got: #{inspect(url)}"
    end

    "Sitemap: " <> url
  end
end
