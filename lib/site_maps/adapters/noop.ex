defmodule SiteMaps.Adapters.Noop do
  @moduledoc """
  Discards every write. Useful for dry runs that only report counts through telemetry.

  `read/2` always returns `{:error, :not_found}` and `list/2` an empty list, so an
  incremental run behaves like the first run.
  """

  @behaviour SiteMaps.Adapter

  @impl true
  def write(_opts, key, _source, _meta), do: SiteMaps.Adapter.validate_key(key)

  @impl true
  def read(_opts, key) do
    with :ok <- SiteMaps.Adapter.validate_key(key), do: {:error, :not_found}
  end

  @impl true
  def delete(_opts, key), do: SiteMaps.Adapter.validate_key(key)

  @impl true
  def list(_opts, _prefix), do: {:ok, []}
end
