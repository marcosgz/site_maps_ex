defmodule SiteMaps.Writer do
  @moduledoc false

  alias SiteMaps.{Config, URL, XML}

  @type file :: %{
          path: Path.t(),
          links: pos_integer,
          news: non_neg_integer,
          bytes: pos_integer,
          lastmod: DateTime.t() | Date.t() | nil
        }

  @doc """
  Writes `urls` into temporary urlset files that never cross the configured limits, calling
  `on_file` with every finished file. Returns the values returned by `on_file`, in order.
  """
  @spec write(Enumerable.t(), Config.t(), (file -> term)) :: [term]
  def write(urls, %Config{} = config, on_file) do
    header = XML.urlset_header(config)
    footer = XML.urlset_footer()
    sizes = %{header: IO.iodata_length(header), footer: IO.iodata_length(footer)}
    acc = %{file: nil, emitted: [], config: config, header: header, footer: footer, sizes: sizes, on_file: on_file}

    try do
      urls
      |> Enum.reduce(acc, &add/2)
      |> close()
      |> Map.fetch!(:emitted)
      |> Enum.reverse()
    catch
      kind, reason ->
        discard(Process.get(:site_maps_writer_file))
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Process.delete(:site_maps_writer_file)
    end
  end

  defp add(%URL{} = url, acc) do
    data = XML.url(url, acc.config)
    size = IO.iodata_length(data)
    news = if URL.news?(url), do: 1, else: 0

    acc = if full?(acc, size, news), do: close(acc), else: acc
    acc = if acc.file, do: acc, else: open(acc)

    if acc.file.links == 0 and acc.sizes.header + size + acc.sizes.footer > acc.config.max_bytes do
      raise SiteMaps.EntryTooLargeError, loc: url.loc, bytes: size, max_bytes: acc.config.max_bytes
    end

    put_file(acc, %{
      append(acc.file, data)
      | links: acc.file.links + 1,
        news: acc.file.news + news,
        bytes: acc.file.bytes + size,
        lastmod: latest(acc.file.lastmod, url.lastmod)
    })
  end

  defp add(other, _acc) do
    raise ArgumentError, "sitemap processes must emit SiteMaps.URL structs, got: #{inspect(other)}"
  end

  defp full?(%{file: nil}, _size, _news), do: false

  defp full?(%{file: file, config: config, sizes: sizes}, size, news) do
    file.links + 1 > config.max_links or
      file.bytes + size + sizes.footer > config.max_bytes or
      file.news + news > config.max_news
  end

  defp open(acc) do
    File.mkdir_p!(acc.config.tmp_dir)
    name = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path = Path.join(acc.config.tmp_dir, "site_maps-#{name}.xml")
    io = File.open!(path, [:write, :exclusive, :binary, :raw])
    zlib = if acc.config.gzip?, do: gzip_stream()

    file = %{io: io, zlib: zlib, path: path, links: 0, news: 0, bytes: acc.sizes.header, lastmod: nil}
    put_file(acc, append(file, acc.header))
  end

  defp close(%{file: nil} = acc), do: acc

  defp close(%{file: file} = acc) do
    file = append(file, acc.footer)

    if file.zlib do
      :ok = :file.write(file.io, :zlib.deflate(file.zlib, [], :finish))
      :zlib.deflateEnd(file.zlib)
      :zlib.close(file.zlib)
    end

    :ok = File.close(file.io)
    acc = put_file(acc, nil)
    emitted = acc.on_file.(Map.take(file, [:path, :links, :news, :bytes, :lastmod]))
    %{acc | emitted: [emitted | acc.emitted]}
  end

  defp put_file(acc, file) do
    if file, do: Process.put(:site_maps_writer_file, file), else: Process.delete(:site_maps_writer_file)
    %{acc | file: file}
  end

  defp append(%{zlib: nil, io: io} = file, data) do
    :ok = :file.write(io, data)
    file
  end

  defp append(%{zlib: zlib, io: io} = file, data) do
    :ok = :file.write(io, :zlib.deflate(zlib, data))
    file
  end

  defp gzip_stream do
    zlib = :zlib.open()
    :ok = :zlib.deflateInit(zlib, :default, :deflated, 31, 8, :default)
    zlib
  end

  defp discard(nil), do: :ok

  defp discard(file) do
    if file.zlib, do: :zlib.close(file.zlib)
    File.close(file.io)
    File.rm(file.path)
  end

  @doc false
  def latest(nil, other), do: other
  def latest(current, nil), do: current

  def latest(current, other) do
    if DateTime.compare(to_datetime(other), to_datetime(current)) == :gt, do: other, else: current
  end

  @doc false
  def to_datetime(nil), do: nil
  def to_datetime(%DateTime{} = dt), do: dt
  def to_datetime(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
end
