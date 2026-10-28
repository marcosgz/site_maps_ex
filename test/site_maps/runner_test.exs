defmodule SiteMaps.RunnerTest do
  use ExUnit.Case, async: true

  import SiteMaps.Test.Helpers

  alias SiteMaps.Adapters.Memory
  alias SiteMaps.Test.{Blog, Filtered, Huge, Parts, Single}

  setup do
    {:ok, store} = Memory.start_link()
    %{store: store}
  end

  defp posts(map), do: fn year, month -> Map.get(map, {year, month}, []) end

  describe "full runs" do
    test "writes every process and an index listing them", %{store: store} do
      ctx = %{store: store, posts: posts(%{{2026, 1} => urls(3)})}

      assert {:ok, result} = SiteMaps.generate(Blog, context: ctx)

      assert keys(store) == ["posts/2026-1/sitemap1.xml", "sitemap.xml", "sitemap_static1.xml"]
      assert result.index == "https://blog.test/sitemap.xml"
      assert result.links == 5

      assert locs(read(store, "sitemap.xml")) == [
               "https://blog.test/posts/2026-1/sitemap1.xml",
               "https://blog.test/sitemap_static1.xml"
             ]

      assert locs(read(store, "sitemap_static1.xml")) == ["https://blog.test/", "https://blog.test/about"]
      assert read(store, "sitemap_static1.xml") =~ ~r/\A<\?xml version="1.0" encoding="UTF-8"\?>\n<urlset/
    end

    test "gzips every file when the index URL ends with .gz", %{store: store} do
      ctx = %{store: store, url: "https://blog.test/maps/sitemap.xml.gz"}

      assert {:ok, %{index: "https://blog.test/maps/sitemap.xml.gz"}} = SiteMaps.generate(Blog, context: ctx)

      objects = Memory.dump(store)
      assert Map.keys(objects) |> Enum.sort() == ["sitemap.xml.gz", "sitemap_static1.xml.gz"]
      assert {<<31, 139, _::binary>>, %{content_type: "application/gzip"}} = objects["sitemap_static1.xml.gz"]
      assert locs(read(store, "sitemap.xml.gz")) == ["https://blog.test/maps/sitemap_static1.xml.gz"]
    end

    test "writes a single static process straight to the index URL", %{store: store} do
      assert {:ok, %{index: "https://single.test/sitemap.xml.gz", links: 1}} =
               SiteMaps.generate(Single, context: %{store: store})

      assert keys(store) == ["sitemap.xml.gz"]
      assert read(store, "sitemap.xml.gz") =~ "<urlset"
      assert {_, %{last_modified: ~U[2026-03-01 00:00:00Z]}} = Memory.dump(store)["sitemap.xml.gz"]
    end

    test "falls back to numbered files when the single process outgrows one file", %{store: store} do
      ctx = %{store: store, static: urls(50_001)}

      assert {:ok, %{links: 50_001}} = SiteMaps.generate(Single, context: ctx)
      assert keys(store) == ["sitemap.xml.gz", "sitemap_static1.xml.gz", "sitemap_static2.xml.gz"]
      assert length(locs(read(store, "sitemap_static1.xml.gz"))) == 50_000
    end

    test "sets index lastmod from the newest URL of each file", %{store: store} do
      static = [SiteMaps.url("/a", lastmod: ~D[2026-01-01]), SiteMaps.url("/b", lastmod: ~U[2026-02-03 10:00:00Z])]

      assert {:ok, _} = SiteMaps.generate(Blog, context: %{store: store, static: static})
      assert read(store, "sitemap.xml") =~ "<lastmod>2026-02-03T10:00:00+00:00</lastmod>"
    end

    test "writes nothing and removes the index when no process has URLs", %{store: store} do
      assert {:ok, _} = SiteMaps.generate(Blog, context: %{store: store})
      assert {:ok, %{index: nil, files: []}} = SiteMaps.generate(Blog, context: %{store: store, static: []})
      refute "sitemap.xml" in keys(store)
    end
  end

  describe "protocol limits" do
    test "rotates files at max_links", %{store: store} do
      ctx = %{store: store, config: [max_links: 2], posts: posts(%{{2026, 1} => urls(5)})}

      assert {:ok, _} = SiteMaps.generate(Blog, context: ctx, only: [:posts])

      assert Enum.filter(keys(store), &String.starts_with?(&1, "posts/")) ==
               ~w(posts/2026-1/sitemap1.xml posts/2026-1/sitemap2.xml posts/2026-1/sitemap3.xml)

      assert length(locs(read(store, "posts/2026-1/sitemap3.xml"))) == 1
    end

    test "never writes a file above max_bytes (uncompressed)", %{store: store} do
      static = Enum.map(1..40, &SiteMaps.url("/página/#{&1}/ünïcödé"))
      ctx = %{store: store, url: "https://blog.test/sitemap.xml.gz", static: static, config: [max_bytes: 1_500]}

      assert {:ok, %{files: files}} = SiteMaps.generate(Blog, context: ctx, only: [:static])
      assert length(files) > 2

      for key <- keys(store), key != "sitemap.xml.gz" do
        assert byte_size(read(store, key)) <= 1_500
      end

      all = store |> keys() |> Enum.reject(&(&1 == "sitemap.xml.gz")) |> Enum.flat_map(&locs(read(store, &1)))
      assert length(all) == 40
    end

    test "fails when a single entry cannot fit an empty file", %{store: store} do
      ctx = %{store: store, static: [SiteMaps.url("/" <> String.duplicate("a", 1_500))], config: [max_bytes: 1_000]}

      assert {:error, {:process_failed, :static, %{}, :error, %SiteMaps.EntryTooLargeError{}, _}} =
               SiteMaps.generate(Blog, context: ctx)
    end

    test "rotates news sitemaps at max_news, counting only news entries", %{store: store} do
      news = fn n ->
        SiteMaps.url("/n/#{n}",
          news: [publication_name: "Blog", publication_language: "en", title: "N#{n}", publication_date: ~D[2026-01-01]]
        )
      end

      entries = Enum.map(1..5, news) ++ urls(4, "/plain")
      ctx = %{store: store, news: entries, config: [max_news: 2]}

      assert {:ok, %{news: 5, links: 9}} = SiteMaps.generate(Blog, context: ctx, only: [:news])

      files = store |> keys() |> Enum.filter(&String.starts_with?(&1, "sitemap_news"))
      assert files == ~w(sitemap_news1.xml sitemap_news2.xml sitemap_news3.xml)

      for key <- files, do: assert(length(Regex.scan(~r/<news:news>/, read(store, key))) <= 2)
    end

    test "fails instead of writing an index above max_index_links", %{store: store} do
      ctx = %{store: store, config: [max_links: 1, max_index_links: 2]}

      assert {:error, {:index_too_large, 3, 2}} = SiteMaps.generate(Blog, context: Map.put(ctx, :static, urls(3)))
      refute "sitemap.xml" in keys(store)
    end
  end

  describe "incremental runs" do
    setup %{store: store} do
      ctx = %{
        store: store,
        config: [max_links: 2],
        posts: posts(%{{2026, 1} => urls(5, "/jan"), {2026, 2} => urls(1, "/feb")})
      }

      {:ok, _} =
        SiteMaps.generate(Blog,
          context: ctx,
          only: [:static, posts: [year: 2026, month: 1], posts: [year: 2026, month: 2]]
        )

      %{ctx: ctx}
    end

    test "replaces the regenerated shard and keeps the other index entries", %{store: store, ctx: ctx} do
      ctx = %{ctx | posts: posts(%{{2026, 1} => urls(1, "/jan-new")})}

      assert {:ok, result} = SiteMaps.generate(Blog, context: ctx, only: [posts: [year: 2026, month: 1]])
      assert result.pruned == []

      assert locs(read(store, "sitemap.xml")) == [
               "https://blog.test/posts/2026-1/sitemap1.xml",
               "https://blog.test/posts/2026-2/sitemap1.xml",
               "https://blog.test/sitemap_static1.xml"
             ]

      assert locs(read(store, "posts/2026-1/sitemap1.xml")) == ["https://blog.test/jan-new/1"]
      assert "posts/2026-1/sitemap3.xml" in keys(store)
    end

    test "prunes files of regenerated shards that are no longer listed", %{store: store, ctx: ctx} do
      ctx = %{ctx | posts: posts(%{{2026, 1} => urls(1, "/jan-new")})}

      assert {:ok, %{pruned: pruned}} =
               SiteMaps.generate(Blog, context: ctx, only: [posts: [year: 2026, month: 1]], prune: true)

      assert pruned == ["posts/2026-1/sitemap2.xml", "posts/2026-1/sitemap3.xml"]
      assert keys(store) == ~w(posts/2026-1/sitemap1.xml posts/2026-2/sitemap1.xml sitemap.xml sitemap_static1.xml)
    end

    test "casts string arguments coming from the CLI or job args", %{store: store, ctx: ctx} do
      ctx = %{ctx | posts: posts(%{{2025, 12} => urls(1)})}

      assert {:ok, _} = SiteMaps.generate(Blog, context: ctx, only: [{"posts", %{"year" => "2025", "month" => "12"}}])
      assert "posts/2025-12/sitemap1.xml" in keys(store)
    end

    test "fails on an index it cannot read instead of dropping its entries", %{store: store, ctx: ctx} do
      :ok = Memory.write([pid: store], "sitemap.xml", "<sitemapindex><sitemap>", %{})

      assert {:error, {:index_parse_failed, _}} = SiteMaps.generate(Blog, context: ctx, only: [:static])
    end
  end

  describe "errors" do
    test "a failing process stops the run without touching the index", %{store: store} do
      boom = fn _, _ -> Stream.map([1], fn _ -> raise "boom" end) end
      ctx = %{store: store, posts: boom}

      assert {:error, {:process_failed, :posts, %{year: 2026, month: 1}, :error, %RuntimeError{message: "boom"}, _}} =
               SiteMaps.generate(Blog, context: ctx)

      refute "sitemap.xml" in keys(store)

      assert_raise SiteMaps.Error, ~r/process :posts .* failed: \*\* \(RuntimeError\) boom/, fn ->
        SiteMaps.generate!(Blog, context: ctx)
      end
    end

    test "rejects unknown processes and duplicate executions", %{store: store} do
      assert_raise ArgumentError, ~r/no sitemap process :nope/, fn ->
        SiteMaps.generate(Blog, context: %{store: store}, only: [:nope])
      end

      assert_raise ArgumentError, ~r/enqueued twice/, fn ->
        SiteMaps.generate(Blog, context: %{store: store}, only: [:static, :static])
      end

      assert_raise ArgumentError, ~r/enqueued twice/, fn ->
        SiteMaps.generate(Blog, context: %{store: store}, only: [posts: [year: 2026], posts: [month: 1]])
      end
    end

    test "rejects processes emitting something else than URLs", %{store: store} do
      assert {:error, {:process_failed, :static, _, :error, %ArgumentError{}, _}} =
               SiteMaps.generate(Blog, context: %{store: store, static: ["/oops"]})
    end

    test "reports adapters that cannot read the index" do
      defmodule FailingRead do
        use SiteMaps
        def config(_), do: [url: "https://x.test/sitemap.xml", adapter: SiteMaps.Test.FailingReadAdapter]
        process :a
        process :b, "b"
        def urls(_, _, _), do: [url("/")]
      end

      assert {:error, {:index_read_failed, :boom}} = SiteMaps.generate(FailingRead)
    end
  end

  test "runs many executions concurrently, each in its own files", %{store: store} do
    only = Enum.map(1..20, &{:part, [n: &1]})

    assert {:ok, %{files: files}} = SiteMaps.generate(Parts, context: %{store: store}, only: only, max_concurrency: 8)

    expected = for n <- 1..20, i <- 1..3, do: "parts/#{n}/sitemap#{i}.xml"
    assert store |> keys() |> List.delete("sitemap.xml") |> Enum.sort() == Enum.sort(expected)
    assert length(files) == 60
    assert length(locs(read(store, "sitemap.xml"))) == 60
  end

  test "adds external sitemaps and applies url_filter", %{store: store} do
    ref = make_ref()
    handler = fn _event, _measurements, meta, pid -> send(pid, {ref, meta.loc}) end
    :telemetry.attach("foreign-#{inspect(ref)}", [:site_maps, :url, :foreign_host], handler, self())

    assert {:ok, _} = SiteMaps.generate(Filtered, context: %{store: store})

    index = read(store, "sitemap.xml")
    assert "https://cdn.test/legacy.xml" in locs(index)
    assert "https://cdn.test/other.xml" in locs(index)

    pages = read(store, "sitemap_pages1.xml")
    assert locs(pages) == ["https://filtered.test/home", "https://elsewhere.test/x"]
    assert pages =~ "<priority>0.3</priority>"
    assert_received {^ref, "https://elsewhere.test/x"}
  after
    :telemetry.list_handlers([:site_maps, :url, :foreign_host]) |> Enum.each(&:telemetry.detach(&1.id))
  end

  test "emits telemetry for the run, processes, files and index", %{store: store} do
    ref = make_ref()

    events = [
      [:site_maps, :run, :start],
      [:site_maps, :run, :stop],
      [:site_maps, :process, :stop],
      [:site_maps, :urlset, :write],
      [:site_maps, :index, :write]
    ]

    :telemetry.attach_many(
      "events-#{inspect(ref)}",
      events,
      fn event, m, meta, pid -> send(pid, {ref, event, m, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("events-#{inspect(ref)}") end)

    {:ok, _} = SiteMaps.generate(Blog, context: %{store: store, posts: posts(%{{2026, 1} => urls(1)})})

    assert_received {^ref, [:site_maps, :run, :start], _, %{module: Blog}}
    assert_received {^ref, [:site_maps, :run, :stop], %{duration: _}, %{module: Blog}}
    assert_received {^ref, [:site_maps, :process, :stop], _, %{process: :posts, args: %{year: 2026, month: 1}}}
    assert_received {^ref, [:site_maps, :urlset, :write], %{links: 1}, %{key: "posts/2026-1/sitemap1.xml"}}
    assert_received {^ref, [:site_maps, :index, :write], %{entries: 2}, %{url: "https://blog.test/sitemap.xml"}}
  end

  @tag timeout: 120_000
  test "keeps memory bounded while streaming a large process" do
    assert {:ok, %{links: 120_000, files: files}} = SiteMaps.generate(Huge, context: %{count: 120_000, report: self()})

    assert length(files) == 3
    peaks = collect_memory([])
    assert peaks != []
    assert Enum.max(peaks) < 10_000_000
  end

  defp collect_memory(acc) do
    receive do
      {:memory, bytes} -> collect_memory([bytes | acc])
    after
      0 -> acc
    end
  end
end
