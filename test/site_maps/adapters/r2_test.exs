defmodule SiteMaps.Adapters.R2Test do
  use ExUnit.Case, async: true
  use SiteMaps.AdapterContract, adapter: SiteMaps.Adapters.R2

  alias SiteMaps.Adapters.R2
  alias SiteMaps.FakeS3

  @base_opts [
    account_id: "abc123",
    bucket: "sitemaps",
    prefix: "acme",
    access_key_id: "r2key",
    secret_access_key: "r2secret",
    ex_aws: [
      http_client: ExAws.Request.Req,
      http_opts: [plug: {Req.Test, SiteMaps.FakeS3}],
      retries: [max_attempts: 1]
    ]
  ]

  @meta %{content_type: "application/xml", cache_control: nil, last_modified: nil}

  setup do
    store = FakeS3.start!(page_size: 2)
    Req.Test.stub(FakeS3, {FakeS3, store})
    %{adapter: {R2, @base_opts}, store: store}
  end

  test "targets the account endpoint with region auto and path style", %{store: store} do
    assert :ok = R2.write(@base_opts, "sitemap.xml", "x", @meta)

    [%{host: host, path: path, headers: headers}] = FakeS3.requests(store)
    assert host == "abc123.r2.cloudflarestorage.com"
    assert path == "/sitemaps/acme/sitemap.xml"

    {"authorization", authorization} = List.keyfind(headers, "authorization", 0)
    assert authorization =~ "/auto/s3/aws4_request"
    assert authorization =~ "Credential=r2key/"
    refute List.keymember?(headers, "x-amz-acl", 0)
  end

  test "targets the EU jurisdiction endpoint", %{store: store} do
    assert :ok = R2.write(Keyword.put(@base_opts, :jurisdiction, :eu), "sitemap.xml", "x", @meta)

    assert [%{host: "abc123.eu.r2.cloudflarestorage.com"}] = FakeS3.requests(store)
  end

  test "never sends an acl" do
    opts = R2.s3_opts(@base_opts)

    assert opts[:acl] == nil
    assert opts[:region] == "auto"
    assert opts[:virtual_host] == false
    assert opts[:endpoint] == "https://abc123.r2.cloudflarestorage.com"
    assert_raise NimbleOptions.ValidationError, fn -> R2.s3_opts(Keyword.put(@base_opts, :acl, :public_read)) end
  end

  test "requires an account id" do
    assert_raise NimbleOptions.ValidationError, fn -> R2.s3_opts(Keyword.delete(@base_opts, :account_id)) end
  end
end
