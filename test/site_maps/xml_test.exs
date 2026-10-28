defmodule SiteMaps.XMLTest do
  use ExUnit.Case, async: true

  import SiteMaps.XMLHelpers

  alias SiteMaps.{Config, IndexEntry, URL, XML}

  doctest SiteMaps.XML

  @video [
    thumbnail_loc: "https://acme.com/thumb.jpg",
    title: "Video title",
    description: "Video description",
    content_loc: "https://acme.com/video.mp4"
  ]

  @news [
    publication_name: "Acme Times",
    publication_language: "en",
    title: "Headline",
    publication_date: ~U[2026-03-01 10:00:00Z]
  ]

  defp config(opts \\ []) do
    struct!(
      %Config{
        url: "https://acme.com/sitemaps/sitemap.xml",
        root_uri: URI.parse("https://acme.com/sitemaps/"),
        index_key: "sitemap.xml",
        adapter: {SiteMaps.Adapters.Noop, []}
      },
      opts
    )
  end

  defp render(url, config \\ config()), do: url |> XML.url(config) |> IO.iodata_to_binary()
  defp doc(url, config \\ config()), do: url |> XML.url(config) |> urlset(config) |> parse()
  defp url(opts \\ []), do: URL.new("https://acme.com/page", opts)

  describe "urlset_header/1 and urlset_footer/0" do
    test "declares every namespace" do
      header = config() |> XML.urlset_header() |> IO.iodata_to_binary()

      assert header =~ ~s(<?xml version="1.0" encoding="UTF-8"?>\n<urlset )

      for ns <- [
            ~s(xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"),
            ~s(xmlns:xhtml="http://www.w3.org/1999/xhtml"),
            ~s(xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"),
            ~s(xmlns:video="http://www.google.com/schemas/sitemap-video/1.1"),
            ~s(xmlns:news="http://www.google.com/schemas/sitemap-news/0.9"),
            ~s(xmlns:mobile="http://www.google.com/schemas/sitemap-mobile/1.0"),
            ~s(xmlns:pagemap="http://www.google.com/schemas/sitemap-pagemap/1.0")
          ] do
        assert header =~ ns
      end

      refute header =~ "xml-stylesheet"
      assert IO.iodata_to_binary(XML.urlset_footer()) == "</urlset>\n"
    end

    test "adds an escaped stylesheet instruction" do
      header = [xsl_stylesheet_url: "/style.xsl?a=1&b=2"] |> config() |> XML.urlset_header() |> IO.iodata_to_binary()

      assert header =~
               ~s(<?xml version="1.0" encoding="UTF-8"?>\n<?xml-stylesheet type="text/xsl" href="/style.xsl?a=1&amp;b=2"?>\n<urlset)
    end

    test "an empty urlset is well formed" do
      doc = parse([XML.urlset_header(config()), XML.urlset_footer()])
      assert count(doc, "/sm:urlset/sm:url") == 0
    end
  end

  describe "url/2 core elements" do
    test "writes only the loc when nothing else is set" do
      assert render(url()) == "<url><loc>https://acme.com/page</loc></url>\n"
    end

    test "never writes expires" do
      refute render(url(lastmod: ~D[2026-03-01], changefreq: :daily, priority: 0.5)) =~ "expires"
    end

    test "writes lastmod, changefreq and priority in XSD order" do
      doc = doc(url(lastmod: ~N[2026-03-01 10:00:00], changefreq: :daily, priority: 1))

      assert child_names(doc, "/sm:urlset/sm:url") == ~w(loc lastmod changefreq priority)
      assert xpath(doc, "//sm:url/sm:lastmod/text()") == "2026-03-01T10:00:00+00:00"
      assert xpath(doc, "//sm:url/sm:changefreq/text()") == "daily"
      assert xpath(doc, "//sm:url/sm:priority/text()") == "1.0"
    end

    test "writes priority with one decimal" do
      for {priority, expected} <- [{0, "0.0"}, {0.5, "0.5"}, {0.25, "0.3"}, {0.94, "0.9"}, {1.0, "1.0"}] do
        assert render(url(priority: priority)) =~ "<priority>#{expected}</priority>"
      end
    end

    test "writes a Date lastmod as YYYY-MM-DD" do
      assert render(url(lastmod: ~D[2026-03-01])) =~ "<lastmod>2026-03-01</lastmod>"
    end

    test "applies config defaults only when the url has no value" do
      config = config(default_changefreq: :weekly, default_priority: 0.5)

      assert render(url(), config) =~ "<changefreq>weekly</changefreq><priority>0.5</priority>"

      assert render(url(changefreq: :never, priority: 0.0), config) =~
               "<changefreq>never</changefreq><priority>0.0</priority>"
    end
  end

  describe "escaping" do
    test "escapes the five entities in text and attributes" do
      xml =
        render(
          URL.new("https://acme.com/?a=1&b=<2>",
            images: [loc: "https://acme.com/i.jpg?x='1'&y=\"2\"", caption: "Tom & Jerry <3"],
            alternates: [href: "https://acme.com/pt?a=1&b=2", lang: "pt"]
          )
        )

      assert xml =~ "<loc>https://acme.com/?a=1&amp;b=&lt;2&gt;</loc>"
      assert xml =~ "<image:loc>https://acme.com/i.jpg?x=&apos;1&apos;&amp;y=&quot;2&quot;</image:loc>"
      assert xml =~ "<image:caption>Tom &amp; Jerry &lt;3</image:caption>"
      assert xml =~ ~s(href="https://acme.com/pt?a=1&amp;b=2")
    end

    test "round-trips through a parser" do
      doc = doc(URL.new("https://acme.com/?q=a&b='c'\"d\"<e>"))
      assert xpath(doc, "//sm:url/sm:loc/text()") == "https://acme.com/?q=a&b='c'\"d\"<e>"
    end

    test "keeps non-ASCII text intact" do
      xml = render(url(news: Keyword.put(@news, :title, "Ação São Paulo — 東京 🎉")))
      assert xml =~ "<news:title>Ação São Paulo — 東京 🎉</news:title>"
    end

    test "drops characters invalid in XML 1.0" do
      escaped = ("a\0b\x01c\td\ne\rf\x7F￾g" <> <<0xFF>> <> "h") |> XML.escape() |> IO.iodata_to_binary()
      assert escaped == "abc\td\ne\rf\x7Fgh"
    end

    test "returns the same binary when nothing needs escaping" do
      value = "plain text é"
      assert XML.escape(value) === value
    end
  end

  describe "news" do
    test "writes required tags in XSD order" do
      doc = doc(url(news: @news))

      assert child_names(doc, "//news:news") == ~w(publication publication_date title)
      assert child_names(doc, "//news:news/news:publication") == ~w(name language)
      assert xpath(doc, "//news:news/news:publication/news:name/text()") == "Acme Times"
      assert xpath(doc, "//news:news/news:publication/news:language/text()") == "en"
      assert xpath(doc, "//news:news/news:publication_date/text()") == "2026-03-01T10:00:00+00:00"
      assert xpath(doc, "//news:news/news:title/text()") == "Headline"
    end

    test "writes deprecated tags only when set, in XSD order" do
      doc =
        doc(
          url(
            news:
              @news ++
                [access: "Subscription", genres: ["Blog", "OpEd"], keywords: "a, b", stock_tickers: ["NASDAQ:A"]]
          )
        )

      assert child_names(doc, "//news:news") ==
               ~w(publication access genres publication_date title keywords stock_tickers)

      assert xpath(doc, "//news:genres/text()") == "Blog, OpEd"
    end

    test "omits empty genres and stock tickers" do
      doc = doc(url(news: @news ++ [genres: [], stock_tickers: []]))
      assert child_names(doc, "//news:news") == ~w(publication publication_date title)
    end

    test "comes after core elements" do
      doc = doc(url(news: @news, priority: 0.5))
      assert child_names(doc, "/sm:urlset/sm:url") == ~w(loc priority news)
    end
  end

  describe "images" do
    test "writes only loc by default" do
      xml = render(url(images: [loc: "https://acme.com/a.jpg"]))
      assert xml =~ "<image:image><image:loc>https://acme.com/a.jpg</image:loc></image:image>"
    end

    test "writes deprecated tags in XSD order" do
      doc =
        doc(
          url(
            images: [
              license: "https://acme.com/license",
              title: "Title",
              geo_location: "Limerick, Ireland",
              caption: "Caption",
              loc: "https://acme.com/a.jpg"
            ]
          )
        )

      assert child_names(doc, "//image:image") == ~w(loc caption geo_location title license)
      assert xpath(doc, "//image:image/image:geo_location/text()") == "Limerick, Ireland"
    end

    test "writes every image" do
      doc = doc(url(images: for(i <- 1..3, do: [loc: "https://acme.com/#{i}.jpg"])))
      assert xpath_all(doc, "//image:image/image:loc/text()") == for(i <- 1..3, do: "https://acme.com/#{i}.jpg")
    end
  end

  describe "videos" do
    test "writes required tags only" do
      doc = doc(url(videos: @video))
      assert child_names(doc, "//video:video") == ~w(thumbnail_loc title description content_loc)
    end

    test "writes every tag in XSD order" do
      video = [
        live: false,
        platform: [relationship: :allow, platforms: [:web, :tv]],
        uploader_info: "https://acme.com/users/1",
        uploader: "Acme",
        requires_subscription: true,
        price: [[value: "1.99", currency: "USD", type: :rent, resolution: :hd], [value: 5, currency: "EUR"]],
        gallery_title: "Gallery",
        gallery_loc: "https://acme.com/gallery",
        restriction: [relationship: :deny, countries: ["US", "CA"]],
        family_friendly: false,
        category: "Sports",
        tags: ["a", "b"],
        publication_date: ~D[2026-03-01],
        view_count: 100,
        rating: 4.25,
        expiration_date: ~N[2026-04-01 00:00:00],
        duration: 600,
        player_loc: "https://acme.com/player?v=1&a=2",
        allow_embed: true,
        autoplay: "ap=1"
      ]

      doc = doc(url(videos: @video ++ video))

      assert child_names(doc, "//video:video") ==
               ~w(thumbnail_loc title description content_loc player_loc duration expiration_date rating view_count
                  publication_date tag tag category family_friendly restriction gallery_loc price price
                  requires_subscription uploader platform live)

      assert xpath(doc, "//video:player_loc/text()") == "https://acme.com/player?v=1&a=2"
      assert xpath(doc, "//video:player_loc/@allow_embed") == "yes"
      assert xpath(doc, "//video:player_loc/@autoplay") == "ap=1"
      assert xpath(doc, "//video:expiration_date/text()") == "2026-04-01T00:00:00+00:00"
      assert xpath(doc, "//video:publication_date/text()") == "2026-03-01"
      assert xpath(doc, "//video:rating/text()") == "4.25"
      assert xpath(doc, "//video:family_friendly/text()") == "no"
      assert xpath(doc, "//video:restriction/text()") == "US CA"
      assert xpath(doc, "//video:restriction/@relationship") == "deny"
      assert xpath(doc, "//video:gallery_loc/@title") == "Gallery"
      assert xpath_all(doc, "//video:price/text()") == ["1.99", "5"]
      assert xpath(doc, "//video:price[1]/@currency") == "USD"
      assert xpath(doc, "//video:price[1]/@type") == "rent"
      assert xpath(doc, "//video:price[1]/@resolution") == "hd"
      assert count(doc, "//video:price[2]/@type") == 0
      assert xpath(doc, "//video:requires_subscription/text()") == "yes"
      assert xpath(doc, "//video:uploader/@info") == "https://acme.com/users/1"
      assert xpath(doc, "//video:platform/text()") == "web tv"
      assert xpath(doc, "//video:platform/@relationship") == "allow"
      assert xpath(doc, "//video:live/text()") == "no"
    end

    test "writes an empty price with its type when there is no value" do
      doc = doc(url(videos: @video ++ [price: [type: :rent, resolution: :sd]]))

      assert xpath_all(doc, "//video:price/text()") == []
      assert xpath(doc, "//video:price/@type") == "rent"
      assert count(doc, "//video:price/@currency") == 0
    end

    test "booleans are omitted when nil, never defaulting to yes" do
      xml = render(url(videos: Keyword.put(@video, :player_loc, "https://acme.com/player")))

      refute xml =~ "allow_embed"
      refute xml =~ "family_friendly"
      refute xml =~ "requires_subscription"
      refute xml =~ "video:live"
    end

    test "uploader without info has no attribute" do
      assert render(url(videos: @video ++ [uploader: "Acme"])) =~ "<video:uploader>Acme</video:uploader>"
    end
  end

  describe "alternates" do
    test "writes xhtml:link with rel, hreflang, href and media" do
      xml =
        render(
          url(
            alternates: [
              [href: "https://acme.com/pt", lang: "pt-BR"],
              [href: "https://m.acme.com/", media: "only screen and (max-width: 640px)", nofollow: true]
            ]
          )
        )

      assert xml =~ ~s(<xhtml:link rel="alternate" hreflang="pt-BR" href="https://acme.com/pt"/>)

      assert xml =~
               ~s[<xhtml:link rel="alternate nofollow" href="https://m.acme.com/" media="only screen and (max-width: 640px)"/>]
    end

    test "comes after images and videos" do
      doc =
        doc(
          url(
            alternates: [href: "https://acme.com/pt", lang: "pt"],
            videos: @video,
            images: [loc: "https://acme.com/a.jpg"],
            news: @news
          )
        )

      assert child_names(doc, "/sm:urlset/sm:url") == ~w(loc news image video link)
    end
  end

  describe "mobile and pagemap" do
    test "are omitted unless set" do
      xml = render(url())
      refute xml =~ "mobile"
      refute xml =~ "PageMap"
    end

    test "mobile writes an empty tag" do
      assert render(url(mobile: true)) =~ "<mobile:mobile/></url>"
    end

    test "pagemap uses the pagemap prefix" do
      doc =
        doc(
          url(
            pagemap: %{
              dataobjects: [
                %{type: "document", id: "d1", attributes: [%{name: "title", value: "A & B"}, %{name: "empty"}]},
                %{type: "thumbnail"}
              ]
            }
          )
        )

      assert count(doc, "//pagemap:PageMap/pagemap:DataObject") == 2
      assert xpath(doc, "//pagemap:DataObject[1]/@type") == "document"
      assert xpath(doc, "//pagemap:DataObject[1]/@id") == "d1"
      assert count(doc, "//pagemap:DataObject[2]/@id") == 0
      assert xpath(doc, "//pagemap:DataObject[1]/pagemap:Attribute[@name='title']/text()") == "A & B"
    end
  end

  describe "index" do
    test "renders header, entries and footer" do
      config = config(xsl_index_stylesheet_url: "/index.xsl", xsl_stylesheet_url: "/urlset.xsl")

      xml =
        IO.iodata_to_binary([
          XML.index_header(config),
          XML.index_entry(%IndexEntry{loc: "https://acme.com/sitemaps/a.xml", lastmod: ~U[2026-03-01 10:00:00Z]}),
          XML.index_entry(%IndexEntry{loc: "https://acme.com/sitemaps/b.xml?x=1&y=2", lastmod: ~D[2026-03-02]}),
          XML.index_entry(%IndexEntry{loc: "https://acme.com/sitemaps/c.xml"}),
          XML.index_footer()
        ])

      assert xml =~ ~s(<?xml-stylesheet type="text/xsl" href="/index.xsl"?>\n<sitemapindex)
      refute xml =~ "urlset.xsl"
      assert String.ends_with?(xml, "</sitemapindex>\n")

      assert xml =~
               "<sitemap><loc>https://acme.com/sitemaps/a.xml</loc><lastmod>2026-03-01T10:00:00+00:00</lastmod></sitemap>\n"

      assert xml =~ "<loc>https://acme.com/sitemaps/b.xml?x=1&amp;y=2</loc><lastmod>2026-03-02</lastmod>"
      assert xml =~ "<sitemap><loc>https://acme.com/sitemaps/c.xml</loc></sitemap>\n"

      doc = parse(xml)
      assert count(doc, "/sm:sitemapindex/sm:sitemap") == 3
    end
  end

  describe "XSD validation" do
    @describetag :xmllint

    setup do
      cond do
        not xmllint?() -> {:skip, "xmllint is not installed"}
        not File.exists?(Path.join(xsd_dir(), "urlset.xsd")) -> {:skip, "vendored XSDs are missing"}
        true -> :ok
      end
    end

    test "a urlset with every extension is valid" do
      config = config(default_changefreq: :weekly, default_priority: 0.5, xsl_stylesheet_url: "/s.xsl")

      urls = [
        URL.new("https://acme.com/"),
        URL.new("https://acme.com/full?a=1&b=2",
          lastmod: ~N[2026-03-01 10:00:00],
          changefreq: :daily,
          priority: 0.75,
          news:
            @news ++
              [
                access: "Registration",
                genres: ["PressRelease", "Satire", "Blog", "OpEd", "Opinion", "UserGenerated"],
                keywords: "a",
                stock_tickers: ~w(NASDAQ:A NYSE:B BOM:500325 LON:D TSE:E)
              ],
          images: [
            [loc: "https://acme.com/a.jpg"],
            [
              loc: "https://acme.com/b.jpg",
              caption: "C",
              geo_location: "G",
              title: "T",
              license: "https://acme.com/l"
            ]
          ],
          videos: [
            @video,
            @video ++
              [
                player_loc: "https://acme.com/player",
                allow_embed: false,
                autoplay: "ap=1",
                duration: 28_800,
                expiration_date: ~D[2027-01-01],
                rating: 4.25,
                view_count: 0,
                publication_date: "2026-03-01T10:00:00+02:00",
                tags: ["a", "steak dinner"],
                title: String.duplicate("e\u0301", 50),
                category: String.duplicate("é", 256),
                family_friendly: true,
                restriction: [relationship: :allow, countries: ["US"]],
                gallery_loc: "https://acme.com/g",
                gallery_title: "G",
                price: [[value: "1.99", currency: "USD", type: :purchase, resolution: :sd], [type: :rent]],
                requires_subscription: false,
                uploader: "U",
                uploader_info: "https://acme.com/u",
                platform: [relationship: :deny, platforms: [:mobile]],
                live: true
              ]
          ],
          alternates: [
            [href: "https://acme.com/pt", lang: "pt-BR"],
            [href: "https://m.acme.com/", media: "x", nofollow: true]
          ],
          mobile: true,
          pagemap: %{dataobjects: [%{type: "doc", id: "1", attributes: [%{name: "n", value: "v"}]}]}
        )
      ]

      xml = IO.iodata_to_binary([XML.urlset_header(config), Enum.map(urls, &XML.url(&1, config)), XML.urlset_footer()])
      assert validate(xml, "urlset.xsd") == :ok
    end

    test "an index is valid" do
      config = config(xsl_index_stylesheet_url: "/i.xsl")

      xml =
        IO.iodata_to_binary([
          XML.index_header(config),
          XML.index_entry(%IndexEntry{loc: "https://acme.com/sitemaps/a.xml", lastmod: ~U[2026-03-01 10:00:00Z]}),
          XML.index_entry(%IndexEntry{loc: "https://acme.com/sitemaps/b.xml", lastmod: ~D[2026-03-01]}),
          XML.index_entry(%IndexEntry{loc: "https://acme.com/sitemaps/c.xml"}),
          XML.index_footer()
        ])

      assert validate(xml, "siteindex.xsd") == :ok
    end

    test "the schema catches out-of-order children" do
      xml =
        IO.iodata_to_binary([
          XML.urlset_header(config()),
          "<url><priority>0.5</priority><loc>https://acme.com/</loc></url>\n",
          XML.urlset_footer()
        ])

      assert {:error, _} = validate(xml, "urlset.xsd")
    end
  end
end
