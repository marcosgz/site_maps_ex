defmodule SiteMaps.Adapters.S3MinioTest do
  use ExUnit.Case, async: false

  @moduletag :minio

  use SiteMaps.AdapterContract, adapter: SiteMaps.Adapters.S3

  setup_all do
    opts = [
      bucket: System.get_env("MINIO_BUCKET", "site-maps-test"),
      endpoint: System.get_env("MINIO_ENDPOINT", "http://localhost:9000"),
      region: System.get_env("MINIO_REGION", "us-east-1"),
      access_key_id: System.get_env("MINIO_ACCESS_KEY", "minioadmin"),
      secret_access_key: System.get_env("MINIO_SECRET_KEY", "minioadmin"),
      ex_aws: [http_client: ExAws.Request.Req, retries: [max_attempts: 1]]
    ]

    config =
      [
        scheme: URI.parse(opts[:endpoint]).scheme <> "://",
        host: URI.parse(opts[:endpoint]).host,
        port: URI.parse(opts[:endpoint]).port
      ] ++ Keyword.take(opts, [:region, :access_key_id, :secret_access_key]) ++ opts[:ex_aws]

    case ExAws.request(ExAws.S3.put_bucket(opts[:bucket], opts[:region]), config) do
      {:ok, _} -> :ok
      {:error, {:http_error, 409, _}} -> :ok
    end

    %{base_opts: opts}
  end

  setup %{base_opts: opts} do
    prefix = "run-#{System.unique_integer([:positive])}"
    %{adapter: {SiteMaps.Adapters.S3, Keyword.put(opts, :prefix, prefix)}}
  end

  @tag :tmp_dir
  test "uploads large files in parts", %{adapter: {mod, opts}, tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "big.xml")
    data = :crypto.strong_rand_bytes(12 * 1024 * 1024)
    File.write!(source, data)

    assert :ok = mod.write(opts, "big.xml", {:file, source}, %{content_type: "application/xml"})
    assert {:ok, ^data, _meta} = mod.read(opts, "big.xml")
  end
end
