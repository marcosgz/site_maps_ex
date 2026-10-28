defmodule SiteMaps.Index do
  @moduledoc false

  alias SiteMaps.{Adapter, Config, IndexEntry, Location, XML}

  @doc """
  Merges the entries of the regenerated families into the existing index, writes it and, when
  `prune?`, deletes family files that are no longer listed.

  Existing entries are kept when they belong to a declared process and were not regenerated;
  entries of removed processes and of former external sitemaps are dropped.
  """
  @spec publish(map, [Location.t()], [IndexEntry.t()], [IndexEntry.t()], boolean) ::
          {:ok, %{entries: [IndexEntry.t()], pruned: [String.t()], written?: boolean}} | {:error, term}
  def publish(%{config: %Config{} = config, module: module}, families, new_entries, externals, prune?) do
    patterns = Enum.map(SiteMaps.processes(module), &Location.pattern(config, &1))

    with {:ok, existing} <- read(config),
         entries = merge(config, patterns, existing, families, new_entries, externals),
         :ok <- check_size(config, entries),
         {:ok, written?} <- write(config, module, entries),
         {:ok, pruned} <- prune(config, families, new_entries, prune?) do
      {:ok, %{entries: entries, pruned: pruned, written?: written?}}
    end
  end

  @doc "Entries of the index currently stored, `[]` when there is none."
  @spec read(Config.t()) :: {:ok, [IndexEntry.t()]} | {:error, term}
  def read(%Config{adapter: adapter, index_key: key}) do
    case Adapter.read(adapter, key) do
      {:ok, data, _meta} -> data |> gunzip() |> parse()
      {:error, :not_found} -> {:ok, []}
      {:error, reason} -> {:error, {:index_read_failed, reason}}
    end
  end

  defp merge(config, patterns, existing, families, new_entries, externals) do
    kept =
      Enum.filter(existing, fn %IndexEntry{loc: loc} ->
        case Config.url_to_key(config, loc) do
          {:ok, key} ->
            key != config.index_key and Enum.any?(patterns, &Regex.match?(&1, key)) and
              not Enum.any?(families, &Location.member?(&1, key))

          :error ->
            false
        end
      end)

    (new_entries ++ externals ++ kept)
    |> Enum.uniq_by(& &1.loc)
    |> Enum.sort_by(& &1.loc)
  end

  defp check_size(%Config{max_index_links: max}, entries) when length(entries) > max,
    do: {:error, {:index_too_large, length(entries), max}}

  defp check_size(_config, _entries), do: :ok

  defp write(%Config{adapter: adapter, index_key: key}, _module, []) do
    case Adapter.delete(adapter, key) do
      :ok -> {:ok, false}
      {:error, reason} -> {:error, {:index_write_failed, reason}}
    end
  end

  defp write(%Config{} = config, module, entries) do
    xml = [XML.index_header(config), Enum.map(entries, &XML.index_entry/1), XML.index_footer()]
    bytes = IO.iodata_length(xml)

    if bytes > config.max_bytes do
      {:error, {:index_too_large, bytes, config.max_bytes}}
    else
      data = if config.gzip?, do: :zlib.gzip(xml), else: xml

      meta = %{
        content_type: if(config.gzip?, do: "application/gzip", else: "application/xml"),
        cache_control: config.cache_control,
        last_modified:
          entries
          |> Enum.map(& &1.lastmod)
          |> Enum.reduce(nil, &SiteMaps.Writer.latest(&2, &1))
          |> SiteMaps.Writer.to_datetime()
      }

      case Adapter.write(config.adapter, config.index_key, data, meta) do
        :ok ->
          :telemetry.execute(
            [:site_maps, :index, :write],
            %{entries: length(entries), bytes: bytes},
            %{module: module, key: config.index_key, url: config.url}
          )

          {:ok, true}

        {:error, reason} ->
          {:error, {:index_write_failed, reason}}
      end
    end
  end

  @doc "Deletes the files of `families` that are not listed in `new_entries`."
  @spec prune(Config.t(), [Location.t()], [IndexEntry.t()], boolean) :: {:ok, [String.t()]} | {:error, term}
  def prune(_config, _families, _new_entries, false), do: {:ok, []}

  def prune(%Config{adapter: adapter} = config, families, new_entries, true) do
    listed = MapSet.new(new_entries, &elem(Config.url_to_key(config, &1.loc), 1))

    families
    |> Enum.uniq_by(&Location.counter_key/1)
    |> Enum.reduce_while({:ok, []}, fn family, {:ok, acc} ->
      with {:ok, keys} <- Adapter.list(adapter, family.dir),
           orphans = Enum.filter(keys, &(Location.member?(family, &1) and not MapSet.member?(listed, &1))),
           :ok <- delete_all(adapter, orphans) do
        {:cont, {:ok, acc ++ orphans}}
      else
        {:error, reason} -> {:halt, {:error, {:prune_failed, reason}}}
      end
    end)
  end

  defp delete_all(adapter, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Adapter.delete(adapter, key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp gunzip(<<31, 139, _::binary>> = data), do: :zlib.gunzip(data)
  defp gunzip(data), do: data

  defp parse(xml) do
    case Saxy.parse_string(xml, SiteMaps.Index.Parser, %{entries: [], current: nil, text: nil, root: nil}) do
      {:ok, %{root: "urlset"}} -> {:ok, []}
      {:ok, %{entries: entries}} -> {:ok, Enum.reverse(entries)}
      {:error, error} -> {:error, {:index_parse_failed, Exception.message(error)}}
    end
  end
end

defmodule SiteMaps.Index.Parser do
  @moduledoc false

  @behaviour Saxy.Handler

  alias SiteMaps.IndexEntry

  @impl true
  def handle_event(:start_element, {name, _attrs}, %{root: nil} = state), do: {:ok, %{state | root: local(name)}}

  def handle_event(:start_element, {name, _attrs}, state) do
    case local(name) do
      "sitemap" -> {:ok, %{state | current: %{loc: nil, lastmod: nil}}}
      tag when tag in ["loc", "lastmod"] -> {:ok, %{state | text: ""}}
      _ -> {:ok, state}
    end
  end

  def handle_event(:characters, chars, %{text: text} = state) when is_binary(text),
    do: {:ok, %{state | text: text <> chars}}

  def handle_event(:end_element, name, %{current: current} = state) when is_map(current) do
    case local(name) do
      "loc" ->
        {:ok, %{state | current: %{current | loc: String.trim(state.text)}, text: nil}}

      "lastmod" ->
        {:ok, %{state | current: %{current | lastmod: lastmod(state.text)}, text: nil}}

      "sitemap" when is_binary(current.loc) ->
        {:ok, %{state | entries: [struct(IndexEntry, current) | state.entries], current: nil}}

      "sitemap" ->
        {:ok, %{state | current: nil}}

      _ ->
        {:ok, state}
    end
  end

  def handle_event(_event, _data, state), do: {:ok, state}

  defp local(name), do: name |> String.split(":") |> List.last()

  defp lastmod(text) do
    text = String.trim(text)

    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        case Date.from_iso8601(text) do
          {:ok, date} -> date
          _ -> nil
        end
    end
  end
end
