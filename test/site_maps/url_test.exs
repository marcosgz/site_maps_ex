defmodule SiteMaps.URLTest do
  use ExUnit.Case, async: true

  alias SiteMaps.URL

  @video [
    thumbnail_loc: "https://acme.com/thumb.jpg",
    title: "Video",
    description: "A video",
    content_loc: "https://acme.com/video.mp4"
  ]

  @news [
    publication_name: "Acme Times",
    publication_language: "en",
    title: "Headline",
    publication_date: ~D[2026-03-01]
  ]

  describe "new/2 defaults" do
    test "sets only the loc" do
      assert %URL{
               loc: "/about",
               lastmod: nil,
               changefreq: nil,
               priority: nil,
               images: [],
               videos: [],
               news: nil,
               alternates: [],
               mobile: false,
               pagemap: nil
             } = URL.new("/about")
    end

    test "accepts a map of options" do
      assert %URL{priority: 0.5} = URL.new("/about", %{priority: 0.5})
    end

    test "rejects unknown options, including expires" do
      assert_raise ArgumentError, ~r/unknown url options \[:expires\]/, fn ->
        URL.new("/about", expires: ~D[2026-01-01])
      end
    end
  end

  describe "loc" do
    test "accepts up to 2047 characters" do
      loc = "https://acme.com/" <> String.duplicate("a", 2047 - 17)
      assert String.length(loc) == 2047
      assert %URL{loc: ^loc} = URL.new(loc)
    end

    test "rejects 2048 characters or more" do
      loc = "https://acme.com/" <> String.duplicate("a", 2048 - 17)
      assert_raise ArgumentError, ~r/less than 2048/, fn -> URL.new(loc) end
    end

    test "counts characters, not bytes" do
      loc = "/" <> String.duplicate("é", 2000)
      assert %URL{} = URL.new(loc)
    end

    test "counts code points, not graphemes" do
      loc = "/" <> String.duplicate("e\u0301", 1023)
      assert String.length(loc) == 1024
      assert URL.loc_length(loc) == 2047
      assert %URL{} = URL.new(loc)
      assert_raise ArgumentError, ~r/got 2048/, fn -> URL.new(loc <> "a") end
    end

    test "rejects empty and non-string locs" do
      for loc <- ["", nil, :about, 1] do
        assert_raise ArgumentError, fn -> URL.new(loc) end
      end
    end
  end

  describe "lastmod" do
    test "keeps DateTime and Date" do
      assert URL.new("/", lastmod: ~U[2026-03-01 10:00:00Z]).lastmod == ~U[2026-03-01 10:00:00Z]
      assert URL.new("/", lastmod: ~D[2026-03-01]).lastmod == ~D[2026-03-01]
    end

    test "converts NaiveDateTime to UTC" do
      assert URL.new("/", lastmod: ~N[2026-03-01 10:00:00]).lastmod == ~U[2026-03-01 10:00:00Z]
    end

    test "parses ISO 8601 strings" do
      assert URL.new("/", lastmod: "2026-03-01").lastmod == ~D[2026-03-01]
      assert URL.new("/", lastmod: "2026-03-01T10:00:00+00:00").lastmod == ~U[2026-03-01 10:00:00Z]
    end

    test "raises on integers and unknown types" do
      assert_raise ArgumentError, ~r/lastmod/, fn -> URL.new("/", lastmod: 1_700_000_000) end
      assert_raise ArgumentError, ~r/lastmod/, fn -> URL.new("/", lastmod: "now") end
    end
  end

  describe "changefreq" do
    test "accepts atoms and strings" do
      for freq <- ~w(always hourly daily weekly monthly yearly never) do
        atom = String.to_existing_atom(freq)
        assert URL.new("/", changefreq: atom).changefreq == atom
        assert URL.new("/", changefreq: freq).changefreq == atom
      end
    end

    test "rejects unknown values" do
      for freq <- [:dialy, "Daily", 1] do
        assert_raise ArgumentError, ~r/changefreq/, fn -> URL.new("/", changefreq: freq) end
      end
    end
  end

  describe "priority" do
    test "accepts the 0.0..1.0 boundaries and casts to float" do
      assert URL.new("/", priority: 0).priority == 0.0
      assert URL.new("/", priority: 1).priority == 1.0
      assert URL.new("/", priority: 0.8).priority == 0.8
      assert URL.new("/", priority: "0.3").priority == 0.3
    end

    test "rejects values outside 0.0..1.0" do
      for priority <- [-0.1, 1.1, 2, "high", "0.5x"] do
        assert_raise ArgumentError, ~r/priority/, fn -> URL.new("/", priority: priority) end
      end
    end
  end

  describe "images" do
    test "accepts one image as a map or keyword list" do
      assert [%{loc: "/a.jpg"}] = URL.new("/", images: %{loc: "/a.jpg"}).images
      assert [%{loc: "/a.jpg"}] = URL.new("/", images: [loc: "/a.jpg"]).images
      assert [%{loc: "/a.jpg"}] = URL.new("/", image: [loc: "/a.jpg"]).images
    end

    test "accepts a list and the singular alias" do
      url = URL.new("/", images: [[loc: "/a.jpg"], %{loc: "/b.jpg", title: "B"}], image: %{loc: "/c.jpg"})
      assert Enum.map(url.images, & &1.loc) == ["/a.jpg", "/b.jpg", "/c.jpg"]
    end

    test "allows 1000 images and rejects 1001" do
      images = for i <- 1..1000, do: %{loc: "/#{i}.jpg"}
      assert length(URL.new("/", images: images).images) == 1000

      assert_raise ArgumentError, ~r/at most 1000 images/, fn ->
        URL.new("/", images: [%{loc: "/x.jpg"} | images])
      end
    end

    test "requires loc and rejects unknown keys" do
      assert_raise ArgumentError, ~r/image requires \[:loc\]/, fn -> URL.new("/", images: %{title: "x"}) end
      assert_raise ArgumentError, ~r/unknown image options/, fn -> URL.new("/", images: %{loc: "/a", foo: 1}) end
    end
  end

  describe "videos" do
    test "accepts one or many videos" do
      assert [%{title: "Video"}] = URL.new("/", videos: @video).videos
      assert [_, _] = URL.new("/", videos: [@video, @video]).videos
      assert [_] = URL.new("/", video: @video).videos
    end

    test "requires content_loc or player_loc" do
      assert [_] = URL.new("/", videos: Keyword.put(Keyword.delete(@video, :content_loc), :player_loc, "/p")).videos

      assert_raise ArgumentError, ~r/content_loc or :player_loc/, fn ->
        URL.new("/", videos: Keyword.delete(@video, :content_loc))
      end
    end

    test "requires thumbnail_loc, title and description" do
      for key <- [:thumbnail_loc, :title, :description] do
        assert_raise ArgumentError, ~r/video requires \[:#{key}\]/, fn ->
          URL.new("/", videos: Keyword.delete(@video, key))
        end
      end
    end

    test "keeps booleans three-state" do
      [video] = URL.new("/", videos: @video).videos
      refute Map.has_key?(video, :family_friendly)
      refute Map.has_key?(video, :live)

      [video] =
        URL.new("/",
          videos: @video ++ [family_friendly: false, live: "YES", requires_subscription: "no", allow_embed: true]
        ).videos

      assert %{family_friendly: false, live: true, requires_subscription: false, allow_embed: true} = video
    end

    test "rejects invalid booleans" do
      assert_raise ArgumentError, ~r/live/, fn -> URL.new("/", videos: @video ++ [live: "maybe"]) end
    end

    test "allows 32 tags and rejects 33" do
      tags = for i <- 1..32, do: "t#{i}"
      assert [%{tags: ^tags}] = URL.new("/", videos: @video ++ [tags: tags]).videos

      assert_raise ArgumentError, ~r/at most 32 tags/, fn ->
        URL.new("/", videos: @video ++ [tags: tags, tag: "extra"])
      end
    end

    test "validates duration, rating, title and description" do
      assert_raise ArgumentError, ~r/duration/, fn -> URL.new("/", videos: @video ++ [duration: 28_801]) end
      assert_raise ArgumentError, ~r/rating/, fn -> URL.new("/", videos: @video ++ [rating: 5.1]) end

      assert_raise ArgumentError, ~r/title/, fn ->
        URL.new("/", videos: Keyword.put(@video, :title, String.duplicate("a", 101)))
      end

      assert_raise ArgumentError, ~r/description/, fn ->
        URL.new("/", videos: Keyword.put(@video, :description, String.duplicate("a", 2049)))
      end
    end

    test "limits category to 256 characters" do
      assert [%{category: _}] = URL.new("/", videos: @video ++ [category: String.duplicate("a", 256)]).videos

      assert_raise ArgumentError, ~r/category must have at most 256/, fn ->
        URL.new("/", videos: @video ++ [category: String.duplicate("a", 257)])
      end
    end

    test "counts code points for length limits" do
      title = String.duplicate("e\u0301", 50)
      assert [%{title: ^title}] = URL.new("/", videos: Keyword.put(@video, :title, title)).videos

      assert_raise ArgumentError, ~r/title must have at most 100/, fn ->
        URL.new("/", videos: Keyword.put(@video, :title, title <> "a"))
      end
    end

    test "normalizes restriction, platform and price" do
      [video] =
        URL.new("/",
          videos:
            @video ++
              [
                restriction: [relationship: :allow, countries: "US CA"],
                platform: %{relationship: "deny", platforms: [:tv]},
                price: [value: 1.99, currency: "USD"]
              ]
        ).videos

      assert video.restriction == %{relationship: "allow", values: ["US", "CA"]}
      assert video.platform == %{relationship: "deny", values: ["tv"]}
      assert video.price == [%{value: 1.99, currency: "USD"}]
    end

    test "rejects a price without currency and an invalid relationship" do
      assert_raise ArgumentError, ~r/price requires \[:currency\]/, fn ->
        URL.new("/", videos: @video ++ [price: [value: 1]])
      end

      assert_raise ArgumentError, ~r/relationship/, fn ->
        URL.new("/", videos: @video ++ [restriction: [relationship: :maybe, countries: ["US"]]])
      end
    end

    test "keeps a tag with spaces as one tag" do
      assert [%{tags: ["steak dinner"]}] = URL.new("/", videos: @video ++ [tag: "steak dinner"]).videos
      assert [%{tags: ["a b", "c"]}] = URL.new("/", videos: @video ++ [tags: ["a b"], tag: "c"]).videos
    end

    test "normalizes price type and resolution and allows a price without value when type is set" do
      [video] =
        URL.new("/",
          videos:
            @video ++ [price: [[type: "RENT", resolution: :HD], [value: "0.99", currency: "EUR", type: :purchase]]]
        ).videos

      assert video.price == [
               %{type: "rent", resolution: "hd"},
               %{value: "0.99", currency: "EUR", type: "purchase"}
             ]
    end

    test "rejects invalid price values" do
      for {price, message} <- [
            {[currency: "USD"], ~r/price without value requires \[:type\]/},
            {[value: 1, currency: "usd"], ~r/currency/},
            {[value: 1, currency: :USD], ~r/currency/},
            {[value: -1, currency: "USD"], ~r/non-negative/},
            {[value: "1,99", currency: "USD"], ~r/non-negative/},
            {[value: 1, currency: "USD", type: :buy], ~r/price type/},
            {[value: 1, currency: "USD", resolution: :uhd], ~r/price resolution/}
          ] do
        assert_raise ArgumentError, message, fn -> URL.new("/", videos: @video ++ [price: price]) end
      end
    end

    test "rejects invalid restriction countries and platforms" do
      assert_raise ArgumentError, ~r/restriction countries/, fn ->
        URL.new("/", videos: @video ++ [restriction: [relationship: :allow, countries: ["us"]]])
      end

      assert_raise ArgumentError, ~r/restriction countries/, fn ->
        URL.new("/", videos: @video ++ [restriction: [relationship: :allow, countries: ["USA"]]])
      end

      assert_raise ArgumentError, ~r/platform platforms/, fn ->
        URL.new("/", videos: @video ++ [platform: [relationship: :allow, platforms: [:desktop]]])
      end
    end

    test "requires autoplay to be a string" do
      assert [%{autoplay: "ap=1"}] = URL.new("/", videos: @video ++ [autoplay: "ap=1"]).videos
      assert_raise ArgumentError, ~r/autoplay/, fn -> URL.new("/", videos: @video ++ [autoplay: true]) end
    end
  end

  describe "news" do
    test "normalizes the publication date and lists" do
      url = URL.new("/", news: @news ++ [keywords: ["a", "b"], genres: ["Blog", "OpEd"], stock_tickers: "NASDAQ:A"])

      assert URL.news?(url)
      assert url.news.publication_date == ~D[2026-03-01]
      assert url.news.keywords == "a, b"
      assert url.news.genres == "Blog, OpEd"
      assert url.news.stock_tickers == "NASDAQ:A"
    end

    test "requires name, language, title and publication date" do
      for key <- [:publication_name, :publication_language, :title, :publication_date] do
        assert_raise ArgumentError, ~r/news requires \[:#{key}\]/, fn ->
          URL.new("/", news: Keyword.delete(@news, key))
        end
      end
    end

    test "validates the publication language" do
      for language <- ["en", "por", "zh-cn", "zh-tw"] do
        assert URL.new("/", news: Keyword.put(@news, :publication_language, language)).news.publication_language ==
                 language
      end

      for language <- ["pt-BR", "EN", "english", :en] do
        assert_raise ArgumentError, ~r/publication_language/, fn ->
          URL.new("/", news: Keyword.put(@news, :publication_language, language))
        end
      end
    end

    test "accepts only Subscription or Registration access" do
      assert URL.new("/", news: @news ++ [access: "Registration"]).news.access == "Registration"

      for access <- ["Free", "subscription", :subscription] do
        assert_raise ArgumentError, ~r/news access/, fn -> URL.new("/", news: @news ++ [access: access]) end
      end
    end

    test "validates genres and omits empty ones" do
      assert URL.new("/", news: @news ++ [genres: "PressRelease,Satire , UserGenerated"]).news.genres ==
               "PressRelease, Satire, UserGenerated"

      refute Map.has_key?(URL.new("/", news: @news ++ [genres: []]).news, :genres)
      refute Map.has_key?(URL.new("/", news: @news ++ [genres: ""]).news, :genres)

      assert_raise ArgumentError, ~r/news genres.*"Sports"/, fn ->
        URL.new("/", news: @news ++ [genres: ["Blog", "Sports"]])
      end
    end

    test "validates stock tickers" do
      tickers = ~w(NASDAQ:A NASDAQ:B NYSE:C BOM:500325 NASDAQ:E)
      assert URL.new("/", news: @news ++ [stock_tickers: tickers]).news.stock_tickers == Enum.join(tickers, ", ")
      refute Map.has_key?(URL.new("/", news: @news ++ [stock_tickers: []]).news, :stock_tickers)

      assert_raise ArgumentError, ~r/at most 5 stock_tickers/, fn ->
        URL.new("/", news: @news ++ [stock_tickers: tickers ++ ["NYSE:F"]])
      end

      for ticker <- ["AMAT", "NASDAQ:", "NAS DAQ:A", "NASDAQ:A:B"] do
        assert_raise ArgumentError, ~r/stock_tickers must look like/, fn ->
          URL.new("/", news: @news ++ [stock_tickers: [ticker]])
        end
      end
    end

    test "news?/1 is false without news" do
      refute URL.news?(URL.new("/"))
    end
  end

  describe "alternates" do
    test "accepts one or many and the hreflang alias" do
      url = URL.new("/", alternates: [href: "/pt", lang: "pt-BR"], alternate: %{href: "/es", hreflang: "es"})

      assert url.alternates == [
               %{href: "/pt", lang: "pt-BR", nofollow: false},
               %{href: "/es", lang: "es", nofollow: false}
             ]
    end

    test "requires href" do
      assert_raise ArgumentError, ~r/alternate requires \[:href\]/, fn -> URL.new("/", alternates: [lang: "pt"]) end
    end
  end

  describe "map_locs/2" do
    test "applies the function to every nested URL field" do
      url =
        URL.new("/page",
          images: [[loc: "/a.jpg", license: "/license"], [loc: "/b.jpg", title: "B"]],
          videos: [
            @video,
            [
              thumbnail_loc: "/t.jpg",
              title: "T",
              description: "D",
              player_loc: "/p",
              gallery_loc: "/g",
              uploader: "U",
              uploader_info: "/u"
            ]
          ],
          alternates: [href: "/pt", lang: "pt"]
        )

      mapped = URL.map_locs(url, &("https://x.com" <> &1))

      assert mapped.loc == "/page"

      assert mapped.images == [
               %{loc: "https://x.com/a.jpg", license: "https://x.com/license"},
               %{loc: "https://x.com/b.jpg", title: "B"}
             ]

      assert [first, second] = mapped.videos
      assert first.thumbnail_loc == "https://x.comhttps://acme.com/thumb.jpg"
      assert first.content_loc == "https://x.comhttps://acme.com/video.mp4"
      refute Map.has_key?(first, :player_loc)
      assert second.thumbnail_loc == "https://x.com/t.jpg"
      assert second.player_loc == "https://x.com/p"
      assert second.gallery_loc == "https://x.com/g"
      assert second.uploader_info == "https://x.com/u"
      assert second.title == "T"
      assert [%{href: "https://x.com/pt", lang: "pt"}] = mapped.alternates
    end

    test "returns the url unchanged without nested fields" do
      url = URL.new("/page")
      assert URL.map_locs(url, fn _ -> flunk("not called") end) == url
    end
  end

  describe "mobile and pagemap" do
    test "mobile must be a boolean" do
      assert URL.new("/", mobile: true).mobile
      assert_raise ArgumentError, ~r/mobile/, fn -> URL.new("/", mobile: "yes") end
    end

    test "normalizes pagemap dataobjects" do
      url =
        URL.new("/",
          pagemap: %{dataobjects: [%{type: "doc", id: "1", attributes: %{name: "title", value: "Hi"}}]}
        )

      assert url.pagemap == %{dataobjects: [%{type: "doc", id: "1", attributes: [%{name: "title", value: "Hi"}]}]}
    end

    test "pagemap dataobjects require a type" do
      assert_raise ArgumentError, ~r/dataobject requires \[:type\]/, fn ->
        URL.new("/", pagemap: %{dataobjects: [%{id: "1"}]})
      end
    end
  end
end
