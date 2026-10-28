defmodule SiteMaps.XML do
  @moduledoc """
  iodata rendering of urlsets and sitemap indexes.

  Only set values are written, every text and attribute is escaped, and child elements follow
  the order of the sitemap, image, video and news XSDs.
  """

  alias SiteMaps.{Config, IndexEntry, URL}

  @declaration ~s(<?xml version="1.0" encoding="UTF-8"?>\n)

  @urlset_open """
  <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" \
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
  xsi:schemaLocation="http://www.sitemaps.org/schemas/sitemap/0.9 http://www.sitemaps.org/schemas/sitemap/0.9/sitemap.xsd" \
  xmlns:xhtml="http://www.w3.org/1999/xhtml" \
  xmlns:image="http://www.google.com/schemas/sitemap-image/1.1" \
  xmlns:video="http://www.google.com/schemas/sitemap-video/1.1" \
  xmlns:news="http://www.google.com/schemas/sitemap-news/0.9" \
  xmlns:mobile="http://www.google.com/schemas/sitemap-mobile/1.0" \
  xmlns:pagemap="http://www.google.com/schemas/sitemap-pagemap/1.0">
  """

  @index_open """
  <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" \
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
  xsi:schemaLocation="http://www.sitemaps.org/schemas/sitemap/0.9 http://www.sitemaps.org/schemas/sitemap/0.9/siteindex.xsd">
  """

  @doc "XML declaration, optional stylesheet instruction and the opening `<urlset>` with every namespace."
  @spec urlset_header(Config.t()) :: iodata
  def urlset_header(%Config{xsl_stylesheet_url: xsl}), do: [@declaration, stylesheet(xsl), @urlset_open]

  @doc "Closing `</urlset>`."
  @spec urlset_footer() :: iodata
  def urlset_footer, do: "</urlset>\n"

  @doc "XML declaration, optional stylesheet instruction and the opening `<sitemapindex>`."
  @spec index_header(Config.t()) :: iodata
  def index_header(%Config{xsl_index_stylesheet_url: xsl}), do: [@declaration, stylesheet(xsl), @index_open]

  @doc "Closing `</sitemapindex>`."
  @spec index_footer() :: iodata
  def index_footer, do: "</sitemapindex>\n"

  @doc "One `<sitemap>` entry of an index."
  @spec index_entry(IndexEntry.t()) :: iodata
  def index_entry(%IndexEntry{loc: loc, lastmod: lastmod}) do
    ["<sitemap>", element("loc", loc), date_element("lastmod", lastmod), "</sitemap>\n"]
  end

  @doc """
  One `<url>` entry. `default_changefreq` and `default_priority` of `config` apply when the
  entry has no value of its own.
  """
  @spec url(URL.t(), Config.t()) :: iodata
  def url(%URL{} = url, %Config{} = config) do
    [
      "<url>",
      element("loc", url.loc),
      date_element("lastmod", url.lastmod),
      element("changefreq", url.changefreq || config.default_changefreq),
      element("priority", decimal(url.priority || config.default_priority)),
      news(url.news),
      Enum.map(url.images, &image/1),
      Enum.map(url.videos, &video/1),
      Enum.map(url.alternates, &alternate/1),
      mobile(url.mobile),
      pagemap(url.pagemap),
      "</url>\n"
    ]
  end

  @doc """
  Escapes the five XML entities and drops characters that are not allowed in XML 1.0
  (control characters and invalid UTF-8).

      iex> SiteMaps.XML.escape("a&b <c> \\"d\\" 'e'") |> IO.iodata_to_binary()
      "a&amp;b &lt;c&gt; &quot;d&quot; &apos;e&apos;"
  """
  @spec escape(String.t()) :: iodata
  def escape(value) when is_binary(value) do
    case escape(value, value, 0, 0) do
      [^value] -> value
      iodata -> iodata
    end
  end

  defp escape(<<char, rest::binary>>, original, skip, len) when char in ~c"&<>\"'" do
    [binary_part(original, skip, len), entity(char) | escape(rest, original, skip + len + 1, 0)]
  end

  defp escape(<<char, rest::binary>>, original, skip, len) when char in 0x20..0x7F or char in [0x9, 0xA, 0xD] do
    escape(rest, original, skip, len + 1)
  end

  defp escape(<<char::utf8, rest::binary>> = bin, original, skip, len) when char > 0x7F do
    size = byte_size(bin) - byte_size(rest)

    if char in 0xFFFE..0xFFFF do
      [binary_part(original, skip, len) | escape(rest, original, skip + len + size, 0)]
    else
      escape(rest, original, skip, len + size)
    end
  end

  defp escape(<<_byte, rest::binary>>, original, skip, len) do
    [binary_part(original, skip, len) | escape(rest, original, skip + len + 1, 0)]
  end

  defp escape(<<>>, original, skip, len), do: [binary_part(original, skip, len)]

  defp entity(?&), do: "&amp;"
  defp entity(?<), do: "&lt;"
  defp entity(?>), do: "&gt;"
  defp entity(?"), do: "&quot;"
  defp entity(?'), do: "&apos;"

  defp stylesheet(nil), do: []
  defp stylesheet(url), do: [~s(<?xml-stylesheet type="text/xsl" href="), escape(url), ~s("?>\n)]

  defp news(nil), do: []

  defp news(news) do
    [
      "<news:news><news:publication>",
      element("news:name", news.publication_name),
      element("news:language", news.publication_language),
      "</news:publication>",
      element("news:access", news[:access]),
      element("news:genres", news[:genres]),
      date_element("news:publication_date", news.publication_date),
      element("news:title", news.title),
      element("news:keywords", news[:keywords]),
      element("news:stock_tickers", news[:stock_tickers]),
      "</news:news>"
    ]
  end

  defp image(image) do
    [
      "<image:image>",
      element("image:loc", image.loc),
      element("image:caption", image[:caption]),
      element("image:geo_location", image[:geo_location]),
      element("image:title", image[:title]),
      element("image:license", image[:license]),
      "</image:image>"
    ]
  end

  defp video(video) do
    [
      "<video:video>",
      element("video:thumbnail_loc", video.thumbnail_loc),
      element("video:title", video.title),
      element("video:description", video.description),
      element("video:content_loc", video[:content_loc]),
      element("video:player_loc", video[:player_loc],
        allow_embed: yes_no(video[:allow_embed]),
        autoplay: video[:autoplay]
      ),
      element("video:duration", video[:duration]),
      date_element("video:expiration_date", video[:expiration_date]),
      element("video:rating", rating(video[:rating])),
      element("video:view_count", video[:view_count]),
      date_element("video:publication_date", video[:publication_date]),
      Enum.map(video.tags, &element("video:tag", &1)),
      element("video:category", video[:category]),
      element("video:family_friendly", yes_no(video[:family_friendly])),
      relationship("video:restriction", video[:restriction]),
      element("video:gallery_loc", video[:gallery_loc], title: video[:gallery_title]),
      Enum.map(video.price, &price/1),
      element("video:requires_subscription", yes_no(video[:requires_subscription])),
      element("video:uploader", video[:uploader], info: video[:uploader_info]),
      relationship("video:platform", video[:platform]),
      element("video:live", yes_no(video[:live])),
      "</video:video>"
    ]
  end

  defp relationship(_name, nil), do: []

  defp relationship(name, %{relationship: relationship, values: values}) do
    element(name, Enum.join(values, " "), relationship: relationship)
  end

  defp price(price) do
    element("video:price", price[:value] || "",
      currency: price[:currency],
      type: price[:type],
      resolution: price[:resolution]
    )
  end

  defp alternate(alternate) do
    rel = if alternate.nofollow, do: "alternate nofollow", else: "alternate"
    attrs = attributes(rel: rel, hreflang: alternate[:lang], href: alternate.href, media: alternate[:media])
    ["<xhtml:link", attrs, "/>"]
  end

  defp mobile(true), do: "<mobile:mobile/>"
  defp mobile(false), do: []

  defp pagemap(nil), do: []

  defp pagemap(%{dataobjects: dataobjects}) do
    ["<pagemap:PageMap>", Enum.map(dataobjects, &dataobject/1), "</pagemap:PageMap>"]
  end

  defp dataobject(dataobject) do
    [
      "<pagemap:DataObject",
      attributes(type: dataobject.type, id: dataobject[:id]),
      ">",
      Enum.map(dataobject.attributes, &element("pagemap:Attribute", &1[:value] || "", name: &1.name)),
      "</pagemap:DataObject>"
    ]
  end

  defp element(name, value, attrs \\ [])
  defp element(_name, nil, _attrs), do: []

  defp element(name, value, attrs) do
    ["<", name, attributes(attrs), ">", text(value), "</", name, ">"]
  end

  defp date_element(_name, nil), do: []
  defp date_element(name, date), do: element(name, SiteMaps.Date.w3c(date))

  defp attributes(attrs) do
    for {key, value} <- attrs, value != nil, do: [" ", Atom.to_string(key), "=\"", text(value), "\""]
  end

  defp text(value) when is_binary(value), do: escape(value)
  defp text(value), do: value |> to_string() |> escape()

  defp decimal(nil), do: nil
  defp decimal(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp rating(nil), do: nil
  defp rating(value), do: :erlang.float_to_binary(value, [:compact, decimals: 6])

  defp yes_no(nil), do: nil
  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end
