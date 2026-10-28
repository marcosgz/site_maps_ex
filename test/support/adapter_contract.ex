defmodule SiteMaps.AdapterContract do
  @moduledoc """
  Behaviour tests shared by every storage adapter.

      use SiteMaps.AdapterContract, adapter: SiteMaps.Adapters.Memory

  The test module must provide `%{adapter: {module, opts}}` in its setup context.
  """

  defmacro __using__(opts) do
    name = opts |> Keyword.fetch!(:adapter) |> Macro.expand(__CALLER__) |> inspect()

    quote do
      describe "#{unquote(name)} contract" do
        alias SiteMaps.Adapter

        @xml ~s(<?xml version="1.0" encoding="UTF-8"?><urlset><url><loc>https://acme.com/ação</loc></url></urlset>)

        test "round-trips iodata", %{adapter: adapter} do
          assert :ok = Adapter.write(adapter, "sitemap.xml", ["<?xml", [~c" ", @xml]], contract_meta("sitemap.xml"))
          assert {:ok, body, %{content_type: "application/xml"}} = Adapter.read(adapter, "sitemap.xml")
          assert body == "<?xml " <> @xml
        end

        @tag :tmp_dir
        test "round-trips a file source", %{adapter: adapter, tmp_dir: tmp_dir} do
          source = Path.join(tmp_dir, "source.xml")
          File.write!(source, @xml)

          assert :ok =
                   Adapter.write(adapter, "posts/sitemap1.xml", {:file, source}, contract_meta("posts/sitemap1.xml"))

          assert {:ok, @xml, _meta} = Adapter.read(adapter, "posts/sitemap1.xml")
        end

        test "stores gzip bytes untouched", %{adapter: adapter} do
          gzipped = :zlib.gzip(@xml)

          assert :ok = Adapter.write(adapter, "sitemap.xml.gz", gzipped, contract_meta("sitemap.xml.gz"))
          assert {:ok, body, %{content_type: "application/gzip"}} = Adapter.read(adapter, "sitemap.xml.gz")
          assert :zlib.gunzip(body) == @xml
        end

        test "returns not_found for a missing key", %{adapter: adapter} do
          assert {:error, :not_found} = Adapter.read(adapter, "missing.xml")
          assert {:error, :not_found} = Adapter.read(adapter, "missing/dir/sitemap.xml")
        end

        test "overwrites an existing key", %{adapter: adapter} do
          assert :ok = Adapter.write(adapter, "sitemap.xml", "old", contract_meta("sitemap.xml"))
          assert :ok = Adapter.write(adapter, "sitemap.xml", "new", contract_meta("sitemap.xml"))
          assert {:ok, "new", _meta} = Adapter.read(adapter, "sitemap.xml")
          assert {:ok, ["sitemap.xml"]} = Adapter.list(adapter, "")
        end

        test "keeps last_modified", %{adapter: adapter} do
          time = ~U[2026-03-01 10:20:30Z]

          assert :ok = Adapter.write(adapter, "sitemap.xml", @xml, contract_meta("sitemap.xml", time))
          assert {:ok, _body, %{last_modified: read_time}} = Adapter.read(adapter, "sitemap.xml")
          assert DateTime.compare(read_time, time) == :eq
        end

        test "keeps last_modified with second precision", %{adapter: adapter} do
          assert :ok =
                   Adapter.write(
                     adapter,
                     "sitemap.xml",
                     @xml,
                     contract_meta("sitemap.xml", ~U[2026-03-01 10:20:30.123456Z])
                   )

          assert {:ok, _body, %{last_modified: read_time}} = Adapter.read(adapter, "sitemap.xml")
          assert DateTime.compare(read_time, ~U[2026-03-01 10:20:30Z]) == :eq
        end

        test "rejects invalid keys", %{adapter: adapter} do
          for key <-
                ["", "/abs.xml", "a//b.xml", "../up.xml", "a/./b.xml", ".sitemap.xml.0123.tmp", "a\0b.xml"] ++
                  ["a?b.xml", "a#b.xml", "a%20b.xml", "a b.xml", "a\tb.xml", "a\nb.xml", "a\x7fb.xml"] do
            assert {:error, :invalid_key} = Adapter.write(adapter, key, @xml, contract_meta("sitemap.xml"))
            assert {:error, :invalid_key} = Adapter.read(adapter, key)
            assert {:error, :invalid_key} = Adapter.delete(adapter, key)
          end

          assert {:ok, []} = Adapter.list(adapter, "")
        end

        test "reports a last_modified when none is given", %{adapter: adapter} do
          assert :ok = Adapter.write(adapter, "sitemap.xml", @xml, contract_meta("sitemap.xml"))
          assert {:ok, _body, %{last_modified: %DateTime{}}} = Adapter.read(adapter, "sitemap.xml")
        end

        test "lists keys by prefix, sorted and relative", %{adapter: adapter} do
          keys =
            ~w(sitemap.xml posts/2026-03/sitemap2.xml posts/2026-03/sitemap1.xml posts/2026-04/sitemap1.xml news.xml)

          for key <- keys, do: :ok = Adapter.write(adapter, key, @xml, contract_meta(key))

          assert {:ok, all} = Adapter.list(adapter, "")
          assert all == Enum.sort(keys)

          assert {:ok, ["posts/2026-03/sitemap1.xml", "posts/2026-03/sitemap2.xml"]} =
                   Adapter.list(adapter, "posts/2026-03/")

          assert {:ok, ["posts/2026-03/sitemap1.xml", "posts/2026-03/sitemap2.xml", "posts/2026-04/sitemap1.xml"]} =
                   Adapter.list(adapter, "posts/")

          assert {:ok, ["posts/2026-03/sitemap1.xml"]} = Adapter.list(adapter, "posts/2026-03/sitemap1")
          assert {:ok, ["sitemap.xml"]} = Adapter.list(adapter, "site")
          assert {:ok, []} = Adapter.list(adapter, "pages/")
        end

        test "deletes keys and accepts missing ones", %{adapter: adapter} do
          assert :ok = Adapter.write(adapter, "posts/sitemap1.xml", @xml, contract_meta("posts/sitemap1.xml"))
          assert :ok = Adapter.delete(adapter, "posts/sitemap1.xml")
          assert {:error, :not_found} = Adapter.read(adapter, "posts/sitemap1.xml")
          assert {:ok, []} = Adapter.list(adapter, "")
          assert :ok = Adapter.delete(adapter, "posts/sitemap1.xml")
          assert :ok = Adapter.delete(adapter, "never/written.xml")
        end
      end

      defp contract_meta(key, last_modified \\ nil) do
        %{
          content_type: SiteMaps.Adapter.content_type(key),
          cache_control: "public, max-age=60",
          last_modified: last_modified
        }
      end
    end
  end
end
