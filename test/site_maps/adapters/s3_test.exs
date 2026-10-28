defmodule SiteMaps.Adapters.S3Test do
  use ExUnit.Case, async: true
  use SiteMaps.AdapterContract, adapter: SiteMaps.Adapters.S3

  alias SiteMaps.Adapters.S3
  alias SiteMaps.FakeS3

  @base_opts [
    bucket: "sitemaps",
    prefix: "/tenants/acme/",
    endpoint: "http://s3.test:9000",
    region: "us-east-1",
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "secret",
    ex_aws: [
      http_client: ExAws.Request.Req,
      http_opts: [plug: {Req.Test, SiteMaps.FakeS3}],
      retries: [max_attempts: 1]
    ]
  ]

  @min_part_size 5 * 1024 * 1024

  @meta %{content_type: "application/xml", cache_control: "public, max-age=60", last_modified: nil}

  setup do
    store = FakeS3.start!(page_size: 2)
    Req.Test.stub(FakeS3, {FakeS3, store})
    %{adapter: {S3, @base_opts}, store: store}
  end

  test "stores objects under the prefix with path style", %{store: store} do
    assert :ok = S3.write(@base_opts, "posts/sitemap1.xml", "x", @meta)

    assert %{{"sitemaps", "tenants/acme/posts/sitemap1.xml"} => %{body: "x"}} = FakeS3.objects(store)

    assert [%{method: "PUT", host: "s3.test", path: "/sitemaps/tenants/acme/posts/sitemap1.xml"}] =
             FakeS3.requests(store)
  end

  test "sends content type, cache control and last modified metadata", %{store: store} do
    time = ~U[2026-03-01 10:00:00Z]

    assert :ok =
             S3.write(@base_opts, "sitemap.xml.gz", "x", %{
               @meta
               | content_type: "application/gzip",
                 last_modified: time
             })

    [%{headers: headers}] = FakeS3.requests(store)
    assert {"content-type", "application/gzip"} in headers
    assert {"cache-control", "public, max-age=60"} in headers
    assert {"x-amz-meta-given-last-modified", "2026-03-01T10:00:00Z"} in headers
    refute List.keymember?(headers, "x-amz-acl", 0)
    refute List.keymember?(headers, "x-amz-storage-class", 0)
  end

  test "sends acl, storage class and cache control overrides when configured", %{store: store} do
    opts = Keyword.merge(@base_opts, acl: :public_read, storage_class: :standard_ia, cache_control: "no-cache")
    assert :ok = S3.write(opts, "sitemap.xml", "x", @meta)

    [%{headers: headers}] = FakeS3.requests(store)
    assert {"x-amz-acl", "public-read"} in headers
    assert {"x-amz-storage-class", "STANDARD_IA"} in headers
    assert {"cache-control", "no-cache"} in headers
  end

  @tag :tmp_dir
  test "uploads large files in parts", %{store: store, tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "big.xml")
    data = :crypto.strong_rand_bytes(2 * @min_part_size + 1_000)
    File.write!(source, data)
    opts = Keyword.merge(@base_opts, multipart_threshold: @min_part_size, part_size: @min_part_size)

    assert :ok = S3.write(opts, "big.xml", {:file, source}, @meta)
    assert {:ok, ^data, %{content_type: "application/xml"}} = S3.read(opts, "big.xml")

    requests = FakeS3.requests(store)
    assert Enum.count(requests, &match?(%{method: "PUT", query: %{"partNumber" => _}}, &1)) == 3
    assert Enum.any?(requests, &match?(%{method: "POST", query: %{"uploads" => _}}, &1))
  end

  @tag :tmp_dir
  test "aborts the multipart upload when a part fails", %{store: store, tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "big.xml")
    File.write!(source, :crypto.strong_rand_bytes(2 * @min_part_size + 1_000))
    opts = Keyword.merge(@base_opts, multipart_threshold: @min_part_size, part_size: @min_part_size)

    Req.Test.stub(FakeS3, fn
      %{method: "PUT", query_string: "partNumber=2" <> _} = conn -> Plug.Conn.send_resp(conn, 403, "")
      conn -> FakeS3.call(conn, store)
    end)

    assert {:error, {:http_error, 403, _}} = S3.write(opts, "big.xml", {:file, source}, @meta)
    assert Enum.any?(FakeS3.requests(store), &match?(%{method: "DELETE", query: %{"uploadId" => _}}, &1))
    assert FakeS3.objects(store) == %{}
  end

  @tag :tmp_dir
  test "aborts the multipart upload when a part raises", %{store: store, tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "big.xml")
    File.write!(source, :crypto.strong_rand_bytes(2 * @min_part_size + 1_000))
    opts = Keyword.merge(@base_opts, multipart_threshold: @min_part_size, part_size: @min_part_size)

    Req.Test.stub(FakeS3, fn
      %{method: "PUT", query_string: "partNumber=2" <> _} -> raise "connection lost"
      conn -> FakeS3.call(conn, store)
    end)

    assert_raise RuntimeError, "connection lost", fn -> S3.write(opts, "big.xml", {:file, source}, @meta) end
    assert Enum.any?(FakeS3.requests(store), &match?(%{method: "DELETE", query: %{"uploadId" => _}}, &1))
    assert FakeS3.objects(store) == %{}
  end

  @tag :tmp_dir
  @tag :capture_log
  test "aborts the multipart upload when completing fails", %{store: store, tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "big.xml")
    File.write!(source, :crypto.strong_rand_bytes(@min_part_size + 1_000))
    opts = Keyword.merge(@base_opts, multipart_threshold: @min_part_size, part_size: @min_part_size)

    Req.Test.stub(FakeS3, fn
      %{method: "POST", query_string: "uploadId=" <> _} = conn -> Req.Test.transport_error(conn, :closed)
      conn -> FakeS3.call(conn, store)
    end)

    assert {:error, _reason} = S3.write(opts, "big.xml", {:file, source}, @meta)
    assert Enum.any?(FakeS3.requests(store), &match?(%{method: "DELETE", query: %{"uploadId" => _}}, &1))
  end

  test "rejects a part_size below 5 MiB" do
    assert_raise NimbleOptions.ValidationError, ~r/at least 5242880/, fn ->
      S3.write(Keyword.put(@base_opts, :part_size, @min_part_size - 1), "sitemap.xml", "x", @meta)
    end
  end

  test "uses virtual-hosted style when enabled", %{store: store} do
    assert :ok = S3.write(Keyword.put(@base_opts, :virtual_host, true), "sitemap.xml", "x", @meta)
    assert [%{host: "sitemaps.s3.test", path: "/tenants/acme/sitemap.xml"}] = FakeS3.requests(store)
  end

  test "paginates listings", %{store: store} do
    keys = for n <- 1..5, do: "posts/sitemap#{n}.xml"
    for key <- keys, do: :ok = S3.write(@base_opts, key, "x", @meta)

    assert {:ok, ^keys} = S3.list(@base_opts, "posts/")

    list_requests = Enum.filter(FakeS3.requests(store), &match?(%{query: %{"list-type" => "2"}}, &1))
    assert length(list_requests) == 3
    assert Enum.all?(list_requests, &(&1.query["prefix"] == "tenants/acme/posts/"))
  end

  test "works without a prefix", %{store: store} do
    opts = Keyword.delete(@base_opts, :prefix)

    assert :ok = S3.write(opts, "sitemap.xml", "x", @meta)
    assert %{{"sitemaps", "sitemap.xml"} => _} = FakeS3.objects(store)
    assert {:ok, ["sitemap.xml"]} = S3.list(opts, "")
  end

  test "falls back to the Last-Modified header", %{store: store} do
    assert :ok = S3.write(@base_opts, "sitemap.xml", "x", @meta)
    %{{"sitemaps", "tenants/acme/sitemap.xml"} => %{last_modified: stored}} = FakeS3.objects(store)

    assert {:ok, "x", %{last_modified: ^stored}} = S3.read(@base_opts, "sitemap.xml")
  end

  test "returns server errors", %{store: store} do
    FakeS3.fail_with(store, 500)

    assert {:error, {:http_error, 500, _}} = S3.write(@base_opts, "sitemap.xml", "x", @meta)
    assert {:error, {:http_error, 500, _}} = S3.read(@base_opts, "sitemap.xml")
    assert {:error, {:http_error, 500, _}} = S3.list(@base_opts, "")
    assert {:error, {:http_error, 500, _}} = S3.delete(@base_opts, "sitemap.xml")
  end

  test "requires a bucket" do
    assert_raise NimbleOptions.ValidationError, fn -> S3.read([], "sitemap.xml") end
  end
end
