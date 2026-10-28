defmodule SiteMaps.Test.Blog do
  @moduledoc false
  use SiteMaps

  @impl SiteMaps
  def config(ctx) do
    [url: Map.get(ctx, :url, "https://blog.test/sitemap.xml"), adapter: {SiteMaps.Adapters.Memory, pid: ctx.store}] ++
      Map.get(ctx, :config, [])
  end

  process :static

  process :posts, "posts/%{year}-%{month}/sitemap.xml",
    args: [year: :integer, month: :integer],
    defaults: [year: 2026, month: 1]

  process :news, "sitemap_news.xml"

  @impl SiteMaps
  def urls(:static, _args, ctx), do: Map.get(ctx, :static, [url("/"), url("/about")])
  def urls(:posts, %{year: year, month: month}, ctx), do: Map.get(ctx, :posts, fn _, _ -> [] end).(year, month)
  def urls(:news, _args, ctx), do: Map.get(ctx, :news, [])
end

defmodule SiteMaps.Test.Single do
  @moduledoc false
  use SiteMaps

  @impl SiteMaps
  def config(ctx), do: [url: "https://single.test/sitemap.xml.gz", adapter: {SiteMaps.Adapters.Memory, pid: ctx.store}]

  process :static

  @impl SiteMaps
  def urls(:static, _args, ctx), do: Map.get(ctx, :static, [url("/", lastmod: ~D[2026-03-01])])
end

defmodule SiteMaps.Test.Parts do
  @moduledoc false
  use SiteMaps

  @impl SiteMaps
  def config(ctx) do
    [url: "https://parts.test/sitemap.xml", adapter: {SiteMaps.Adapters.Memory, pid: ctx.store}, max_links: 1] ++
      Map.get(ctx, :config, [])
  end

  process :part, "parts/%{n}/sitemap.xml", args: [n: :integer], defaults: [n: 0]

  @impl SiteMaps
  def urls(:part, %{n: n}, _ctx), do: Enum.map(1..3, &url("/parts/#{n}/#{&1}"))
end

defmodule SiteMaps.Test.Filtered do
  @moduledoc false
  use SiteMaps

  @impl SiteMaps
  def config(ctx) do
    [url: "https://filtered.test/sitemap.xml", adapter: {SiteMaps.Adapters.Memory, pid: ctx.store}] ++
      Map.get(ctx, :config, [])
  end

  process :pages
  process :more, "more"

  @impl SiteMaps
  def urls(:pages, _args, _ctx), do: [url("/"), url("/admin"), url("https://elsewhere.test/x")]
  def urls(:more, _args, _ctx), do: [url("/more")]

  @impl SiteMaps
  def external_sitemaps(_ctx), do: [{"https://cdn.test/legacy.xml", ~D[2026-01-01]}, "https://cdn.test/other.xml"]

  @impl SiteMaps
  def url_filter(%SiteMaps.URL{loc: loc} = url, _ctx) do
    cond do
      String.ends_with?(loc, "/admin") -> nil
      String.ends_with?(loc, "/") -> %{url | loc: "/home", priority: 0.3}
      true -> %{url | priority: 0.3}
    end
  end
end

defmodule SiteMaps.Test.Huge do
  @moduledoc false
  use SiteMaps

  @impl SiteMaps
  def config(_ctx), do: [url: "https://huge.test/sitemap.xml.gz", adapter: SiteMaps.Adapters.Noop]

  process :all, "all"

  @impl SiteMaps
  def urls(:all, _args, %{count: count, report: pid}) do
    1..count
    |> Stream.map(&url("/items/#{&1}", lastmod: ~D[2026-01-01]))
    |> Stream.each(fn _ ->
      if :rand.uniform(5_000) == 1, do: send(pid, {:memory, Process.info(self(), :memory) |> elem(1)})
    end)
  end
end

defmodule SiteMaps.Test.FailingReadAdapter do
  @moduledoc false
  @behaviour SiteMaps.Adapter

  @impl true
  def write(_opts, _key, _source, _meta), do: :ok
  @impl true
  def read(_opts, _key), do: {:error, :boom}
  @impl true
  def delete(_opts, _key), do: :ok
  @impl true
  def list(_opts, _prefix), do: {:ok, []}
end

defmodule SiteMaps.Test.Helpers do
  @moduledoc false

  alias SiteMaps.Adapters.Memory

  def read(store, key) do
    {data, _meta} = Map.fetch!(Memory.dump(store), key)
    data = IO.iodata_to_binary(data)
    if String.ends_with?(key, ".gz"), do: :zlib.gunzip(data), else: data
  end

  def keys(store), do: store |> Memory.dump() |> Map.keys() |> Enum.sort()

  def locs(xml), do: ~r/<loc>([^<]+)<\/loc>/ |> Regex.scan(xml) |> Enum.map(&List.last/1)

  def urls(n, prefix \\ "/p"), do: Enum.map(1..n, &SiteMaps.url("#{prefix}/#{&1}"))
end

defmodule SiteMaps.Test.CliSite do
  @moduledoc false
  use SiteMaps

  @impl SiteMaps
  def config(%{dir: dir}),
    do: [url: "https://cli.test/sitemap.xml.gz", adapter: {SiteMaps.Adapters.FileSystem, directory: dir}]

  process :static

  process :archive, "archive/%{year}/%{day}/sitemap.xml",
    args: [year: :integer, day: :date],
    defaults: [year: 2026, day: ~D[2026-01-01]]

  @impl SiteMaps
  def urls(:static, _args, _ctx), do: [url("/")]
  def urls(:archive, %{year: year, day: day}, _ctx), do: [url("/archive/#{year}", lastmod: day)]

  @impl SiteMaps
  def load_context(%{"dir" => dir}), do: %{dir: dir}
end

defmodule SiteMaps.Test.Monthly do
  @moduledoc false
  use SiteMaps

  @impl SiteMaps
  def config(ctx),
    do: [url: "https://m.test/sitemap.xml", adapter: {SiteMaps.Adapters.Memory, pid: ctx.store}, max_links: 1]

  process :months, "posts-%{month}.xml", args: [month: :integer], defaults: [month: 1]
  process :tags, "tags/%{tag}/sitemap.xml", args: [tag: :string], defaults: [tag: "all"]

  @impl SiteMaps
  def urls(:months, %{month: month}, ctx), do: Enum.map(1..Map.get(ctx, :count, 1), &url("/m#{month}/#{&1}"))

  def urls(:tags, %{tag: tag}, _ctx),
    do: [url("/tags/#{tag}", images: [loc: "/img/#{tag}.png"], alternates: [href: "/pt/tags/#{tag}", lang: "pt"])]
end
