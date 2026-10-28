defmodule SiteMaps.WebFixtures do
  @moduledoc false

  defmodule Adapter do
    @moduledoc false

    def read(opts, key) do
      send(self(), {:adapter_read, key})

      case Map.fetch(Keyword.fetch!(opts, :files), key) do
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, {body, meta}} -> {:ok, body, Map.merge(%{content_type: nil, last_modified: nil}, meta)}
        {:ok, body} -> {:ok, body, %{content_type: nil, last_modified: nil}}
        :error -> {:error, :not_found}
      end
    end
  end

  defmodule Sitemaps do
    @moduledoc false
    use SiteMaps

    process :static

    @impl SiteMaps
    def config(%{url: url, files: files} = context) do
      [url: url, adapter: {Adapter, files: files}] ++ Map.get(context, :config, [])
    end

    @impl SiteMaps
    def urls(:static, _args, _context), do: []
  end
end
