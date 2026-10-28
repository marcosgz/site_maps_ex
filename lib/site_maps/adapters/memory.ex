defmodule SiteMaps.Adapters.Memory do
  @moduledoc """
  In-memory storage backed by an `Agent`, meant for tests.

      {:ok, pid} = SiteMaps.Adapters.Memory.start_link()
      adapter: {SiteMaps.Adapters.Memory, pid: pid}

  Use `name:` instead of `pid:` to address a named instance. `dump/1` returns the
  stored objects and `history/1` the writes and deletes in the order they happened.
  """

  use Agent

  @behaviour SiteMaps.Adapter

  @type server :: Agent.agent()
  @type object :: {binary, SiteMaps.Adapter.write_meta()}

  @doc "Starts an empty store. Accepts `name:`."
  @spec start_link(keyword) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{objects: %{}, history: []} end, Keyword.take(opts, [:name]))
  end

  @doc "Stored objects as a map of key to `{binary, meta}`."
  @spec dump(server) :: %{String.t() => object}
  def dump(server), do: Agent.get(server, & &1.objects)

  @doc "Writes and deletes in chronological order, as `{:write | :delete, key}`."
  @spec history(server) :: [{:write | :delete, String.t()}]
  def history(server), do: Agent.get(server, &Enum.reverse(&1.history))

  @impl true
  def write(opts, key, source, meta) do
    with :ok <- SiteMaps.Adapter.validate_key(key),
         {:ok, binary} <- to_binary(source) do
      meta = %{
        content_type: meta[:content_type] || SiteMaps.Adapter.content_type(key),
        cache_control: meta[:cache_control],
        last_modified: to_second(meta[:last_modified])
      }

      Agent.update(server(opts), fn state ->
        %{
          state
          | objects: Map.put(state.objects, key, {binary, meta}),
            history: [{:write, key} | state.history]
        }
      end)
    end
  end

  @impl true
  def read(opts, key) do
    with :ok <- SiteMaps.Adapter.validate_key(key) do
      case Agent.get(server(opts), &Map.fetch(&1.objects, key)) do
        {:ok, {binary, meta}} -> {:ok, binary, Map.take(meta, [:content_type, :last_modified])}
        :error -> {:error, :not_found}
      end
    end
  end

  @impl true
  def delete(opts, key) do
    with :ok <- SiteMaps.Adapter.validate_key(key) do
      Agent.update(server(opts), fn state ->
        %{
          state
          | objects: Map.delete(state.objects, key),
            history: [{:delete, key} | state.history]
        }
      end)
    end
  end

  @impl true
  def list(opts, prefix) do
    keys =
      Agent.get(server(opts), fn state ->
        state.objects |> Map.keys() |> Enum.filter(&String.starts_with?(&1, prefix))
      end)

    {:ok, Enum.sort(keys)}
  end

  defp server(opts) do
    opts[:pid] || opts[:name] || raise ArgumentError, "#{inspect(__MODULE__)} requires :pid or :name"
  end

  defp to_second(nil), do: DateTime.utc_now(:second)
  defp to_second(%DateTime{} = time), do: DateTime.truncate(time, :second)

  defp to_binary({:file, path}), do: File.read(path)
  defp to_binary(iodata), do: {:ok, IO.iodata_to_binary(iodata)}
end
