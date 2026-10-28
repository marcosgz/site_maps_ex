defmodule SiteMaps.Adapters.NoopTest do
  use ExUnit.Case, async: true

  alias SiteMaps.Adapters.Noop

  test "discards writes" do
    adapter = {Noop, []}

    assert :ok = SiteMaps.Adapter.write(adapter, "sitemap.xml", "x", %{})
    assert {:error, :not_found} = SiteMaps.Adapter.read(adapter, "sitemap.xml")
    assert {:ok, []} = SiteMaps.Adapter.list(adapter, "")
    assert :ok = SiteMaps.Adapter.delete(adapter, "sitemap.xml")
  end
end
