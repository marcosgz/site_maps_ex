defmodule SiteMaps.Adapters.MemoryTest do
  use ExUnit.Case, async: true
  use SiteMaps.AdapterContract, adapter: SiteMaps.Adapters.Memory

  alias SiteMaps.Adapters.Memory

  setup do
    pid = start_supervised!(Memory)
    %{adapter: {Memory, pid: pid}, pid: pid}
  end

  test "dump/1 exposes stored objects with their meta", %{pid: pid} do
    time = ~U[2026-01-02 03:04:05Z]
    meta = %{content_type: "application/xml", cache_control: "no-cache", last_modified: time}

    assert :ok = Memory.write([pid: pid], "sitemap.xml", ["<a>", "</a>"], meta)
    assert %{"sitemap.xml" => {"<a></a>", ^meta}} = Memory.dump(pid)
  end

  test "history/1 records writes and deletes in order", %{pid: pid} do
    :ok = Memory.write([pid: pid], "a.xml", "a", %{})
    :ok = Memory.write([pid: pid], "b.xml", "b", %{})
    :ok = Memory.delete([pid: pid], "a.xml")

    assert Memory.history(pid) == [write: "a.xml", write: "b.xml", delete: "a.xml"]
  end

  test "addresses a named instance" do
    start_supervised!(Supervisor.child_spec({Memory, name: :site_maps_memory_test}, id: :named))
    adapter = {Memory, name: :site_maps_memory_test}

    assert :ok = SiteMaps.Adapter.write(adapter, "sitemap.xml", "x", %{})
    assert {:ok, "x", %{content_type: "application/xml"}} = SiteMaps.Adapter.read(adapter, "sitemap.xml")
  end

  test "returns the error when a file source is missing", %{pid: pid} do
    assert {:error, :enoent} = Memory.write([pid: pid], "a.xml", {:file, "/nonexistent/a.xml"}, %{})
  end

  test "requires :pid or :name" do
    assert_raise ArgumentError, fn -> Memory.read([], "a.xml") end
  end
end
