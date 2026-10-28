defmodule SiteMaps.Adapters.R2 do
  @schema NimbleOptions.new!(
            account_id: [type: :string, required: true, doc: "Cloudflare account id."],
            jurisdiction: [
              type: {:in, [:default, :eu]},
              default: :default,
              doc: "`:eu` targets buckets created in the EU jurisdiction."
            ],
            bucket: [type: :string, required: true, doc: "Bucket name."],
            prefix: [type: :string, default: "", doc: "Key prefix inside the bucket."],
            access_key_id: [type: :string, doc: "R2 API token access key id."],
            secret_access_key: [type: :string, doc: "R2 API token secret access key."],
            cache_control: [
              type: :string,
              doc: "Overrides the `cache_control` given by the sitemap configuration."
            ],
            multipart_threshold: [
              type: :pos_integer,
              default: 8 * 1024 * 1024,
              doc: "Files larger than this many bytes are uploaded in multiple parts."
            ],
            part_size: [
              type: {:custom, SiteMaps.Adapters.S3, :validate_part_size, []},
              default: 5 * 1024 * 1024,
              doc: "Size in bytes of each multipart part, at least 5 MiB (5242880)."
            ],
            ex_aws: [
              type: :keyword_list,
              default: [],
              doc: "Overrides merged last into the ExAws configuration, such as `http_client`."
            ]
          )

  @moduledoc """
  Stores sitemaps in Cloudflare R2, through its S3-compatible API.

  A preset over `SiteMaps.Adapters.S3` (same optional dependencies): the endpoint
  is `https://<account_id>.r2.cloudflarestorage.com` (or
  `<account_id>.eu.r2.cloudflarestorage.com`), the region is `"auto"`, requests
  use path style and no ACL header is ever sent, because R2 has no object ACLs.

      adapter:
        {SiteMaps.Adapters.R2,
         account_id: "0123456789abcdef",
         bucket: "sitemaps",
         prefix: "acme",
         access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
         secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY")}

  Files can be served through `SiteMaps.Plug` or straight from a public bucket or
  custom domain bound to the bucket.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @behaviour SiteMaps.Adapter

  alias SiteMaps.Adapters.S3

  @impl true
  def write(opts, key, source, meta), do: S3.write(s3_opts(opts), key, source, meta)

  @impl true
  def read(opts, key), do: S3.read(s3_opts(opts), key)

  @impl true
  def delete(opts, key), do: S3.delete(s3_opts(opts), key)

  @impl true
  def list(opts, prefix), do: S3.list(s3_opts(opts), prefix)

  @doc "Translates R2 options into `SiteMaps.Adapters.S3` options."
  @spec s3_opts(keyword) :: keyword
  def s3_opts(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    opts
    |> Keyword.drop([:account_id, :jurisdiction])
    |> Keyword.merge(
      endpoint: endpoint(opts[:account_id], opts[:jurisdiction]),
      region: "auto",
      acl: nil,
      virtual_host: false
    )
  end

  defp endpoint(account_id, :default), do: "https://#{account_id}.r2.cloudflarestorage.com"
  defp endpoint(account_id, :eu), do: "https://#{account_id}.eu.r2.cloudflarestorage.com"
end
