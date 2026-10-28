defmodule SiteMaps.TenancyTest do
  use ExUnit.Case, async: true

  import SiteMaps.Test.Helpers

  alias SiteMaps.Adapters.Memory
  alias SiteMaps.Test.Blog

  @tag :tmp_dir
  test "concurrent generations of different tenants stay isolated", %{tmp_dir: tmp_dir} do
    tenants =
      for n <- 1..12 do
        {:ok, store} = Memory.start_link()

        %{
          store: store,
          url: "https://tenant#{n}.test/sitemap.xml",
          static: urls(30, "/t#{n}"),
          posts: fn _, _ -> Stream.map(1..30, &SiteMaps.url("/t#{n}/post/#{&1}")) end,
          config: [max_links: 7, tmp_dir: tmp_dir]
        }
      end

    results =
      tenants
      |> Enum.flat_map(&[&1, &1])
      |> Task.async_stream(&SiteMaps.generate(Blog, context: &1), max_concurrency: 24, timeout: 60_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{links: 60}}, &1))

    for {ctx, n} <- Enum.with_index(tenants, 1) do
      files = ctx.store |> keys() |> List.delete("sitemap.xml")
      urls = Enum.flat_map(files, &locs(read(ctx.store, &1)))

      assert length(urls) == 60
      assert Enum.all?(urls, &String.starts_with?(&1, "https://tenant#{n}.test/t#{n}/"))
      assert Enum.all?(locs(read(ctx.store, "sitemap.xml")), &String.starts_with?(&1, "https://tenant#{n}.test/"))
    end

    assert File.ls!(tmp_dir) == []
  end
end
