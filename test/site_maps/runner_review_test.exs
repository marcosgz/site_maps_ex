defmodule SiteMaps.RunnerReviewTest do
  use ExUnit.Case, async: true

  import SiteMaps.Test.Helpers

  alias SiteMaps.Adapters.Memory
  alias SiteMaps.Test.{Blog, Filtered, Monthly, Single}

  setup do
    {:ok, store} = Memory.start_link()
    %{store: store}
  end

  test "processes without location write separate families, so partial runs keep each other", %{store: store} do
    defmodule TwoStatic do
      use SiteMaps

      def config(%{store: store}),
        do: [url: "https://two.test/sitemap.xml", adapter: {Memory, pid: store}, max_links: 1]

      process :static
      process :pages
      def urls(:static, _, _), do: [url("/a"), url("/b")]
      def urls(:pages, _, _), do: [url("/p1"), url("/p2")]
    end

    {:ok, _} = SiteMaps.generate(TwoStatic, context: %{store: store})
    {:ok, %{pruned: []}} = SiteMaps.generate(TwoStatic, context: %{store: store}, only: [:static], prune: true)

    assert locs(read(store, "sitemap.xml")) == [
             "https://two.test/sitemap_pages1.xml",
             "https://two.test/sitemap_pages2.xml",
             "https://two.test/sitemap_static1.xml",
             "https://two.test/sitemap_static2.xml"
           ]
  end

  test "rejects dynamic locations that do not interpolate every argument and shared locations" do
    assert_raise CompileError, ~r/must interpolate every argument, missing: %\{year\}/, fn ->
      defmodule NoArgs do
        use SiteMaps
        def config(_), do: []
        process :x, args: [year: :integer]
        def urls(_, _, _), do: []
      end
    end

    assert_raise CompileError, ~r/write to the same location/, fn ->
      defmodule SameLocation do
        use SiteMaps
        def config(_), do: []
        process :a, "/pages"
        process :b, "pages/sitemap.xml"
        def urls(_, _, _), do: []
      end
    end
  end

  test "stems ending in a digit get a separator, so shards never collide", %{store: store} do
    ctx = %{store: store, count: 11}
    {:ok, _} = SiteMaps.generate(Monthly, context: %{ctx | count: 1}, only: [months: [month: 11]])
    {:ok, _} = SiteMaps.generate(Monthly, context: ctx, only: [months: [month: 1]], prune: true)

    assert read(store, "posts-11-1.xml") =~ "/m11/1"
    assert read(store, "posts-1-11.xml") =~ "/m1/11"
    assert "https://m.test/posts-11-1.xml" in locs(read(store, "sitemap.xml"))
  end

  test "rejects interpolated values that are not URL path safe" do
    {:ok, store} = Memory.start_link()

    for tag <- ["a?b", "a#b", "a b", "a/b", "..", "a:b"] do
      assert_raise ArgumentError, ~r/only contain A-Z/, fn ->
        SiteMaps.generate(Monthly, context: %{store: store}, only: [tags: [tag: tag]])
      end
    end
  end

  test "resolves nested image and alternate URLs", %{store: store} do
    {:ok, _} = SiteMaps.generate(Monthly, context: %{store: store}, only: [tags: [tag: "news"]])

    xml = read(store, "tags/news/sitemap1.xml")
    assert xml =~ "<image:loc>https://m.test/img/news.png</image:loc>"
    assert xml =~ ~s(href="https://m.test/pt/tags/news")
  end

  test "drops entries of processes that no longer exist and of former external sitemaps", %{store: store} do
    stale = """
    <?xml version="1.0" encoding="UTF-8"?>
    <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    <sitemap><loc>https://filtered.test/removed/sitemap1.xml</loc></sitemap>
    <sitemap><loc>https://filtered.test/legacy-in-root.xml</loc></sitemap>
    <sitemap><loc>https://cdn.test/gone.xml</loc></sitemap>
    <sitemap><loc>https://filtered.test/more/sitemap1.xml</loc></sitemap>
    </sitemapindex>
    """

    :ok = Memory.write([pid: store], "sitemap.xml", stale, %{})
    {:ok, _} = SiteMaps.generate(Filtered, context: %{store: store}, only: [:pages])

    assert locs(read(store, "sitemap.xml")) == [
             "https://cdn.test/legacy.xml",
             "https://cdn.test/other.xml",
             "https://filtered.test/more/sitemap1.xml",
             "https://filtered.test/sitemap_pages1.xml"
           ]
  end

  test "prunes numbered files when switching to inline mode", %{store: store} do
    {:ok, _} = SiteMaps.generate(Single, context: %{store: store, static: urls(50_001)})
    assert {:ok, %{pruned: pruned}} = SiteMaps.generate(Single, context: %{store: store}, prune: true)

    assert pruned == ["sitemap_static1.xml.gz", "sitemap_static2.xml.gz"]
    assert keys(store) == ["sitemap.xml.gz"]
    assert read(store, "sitemap.xml.gz") =~ "<urlset"
  end

  test "refuses an index URL that collides with a process family", %{store: store} do
    ctx = %{store: store, url: "https://blog.test/sitemap_static1.xml"}

    assert_raise ArgumentError, ~r/may collide/, fn -> SiteMaps.generate(Blog, context: ctx) end
  end

  @tag :tmp_dir
  test "removes its temporary files when a process fails", %{store: store, tmp_dir: tmp_dir} do
    slow = fn _, _ -> Stream.map(1..1_000_000, fn n -> Process.sleep(1) && SiteMaps.url("/s/#{n}") end) end
    boom = Stream.map([1, 2], fn n -> if n == 2, do: raise("boom"), else: SiteMaps.url("/x") end)
    ctx = %{store: store, posts: slow, static: boom, config: [tmp_dir: tmp_dir]}

    assert {:error, {:process_failed, :static, _, :error, %RuntimeError{}, _}} = SiteMaps.generate(Blog, context: ctx)
    assert File.ls!(tmp_dir) == []
  end
end
