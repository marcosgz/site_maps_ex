defmodule SiteMaps.Adapter do
  @moduledoc """
  Storage behaviour used to publish, read, list and delete sitemap files.

  An adapter is configured as a `{module, opts}` tuple. Keys are always relative
  to the adapter root (a directory, a bucket prefix, ...), use `/` as separator
  and never start with `/`.

  Built-in adapters:

    * `SiteMaps.Adapters.FileSystem` - local disk and network mounts (NFS, EFS, SMB)
    * `SiteMaps.Adapters.S3` - AWS S3 and S3-compatible stores (MinIO, Spaces, Wasabi, Ceph)
    * `SiteMaps.Adapters.R2` - Cloudflare R2
    * `SiteMaps.Adapters.Memory` - in-memory storage for tests
    * `SiteMaps.Adapters.Noop` - discards every write (dry runs)

  `read/2` returns the raw stored bytes, so a `.gz` key comes back gzipped.
  A missing key is always reported as `{:error, :not_found}` and deleting a
  missing key is `:ok`. `last_modified` is kept with second precision by every
  adapter.

  Every adapter rejects keys failing `validate_key/1` with `{:error, :invalid_key}`.
  """

  @type opts :: keyword
  @type key :: String.t()
  @type source :: {:file, Path.t()} | iodata
  @type write_meta :: %{
          optional(:content_type) => String.t(),
          optional(:cache_control) => String.t() | nil,
          optional(:last_modified) => DateTime.t() | nil
        }
  @type read_meta :: %{content_type: String.t() | nil, last_modified: DateTime.t() | nil}
  @type t :: {module, opts}

  @callback write(opts, key, source, write_meta) :: :ok | {:error, term}
  @callback read(opts, key) :: {:ok, binary, read_meta} | {:error, :not_found | term}
  @callback delete(opts, key) :: :ok | {:error, term}
  @callback list(opts, prefix :: String.t()) :: {:ok, [key]} | {:error, term}

  @doc "Stores `source` under `key`."
  @spec write(t, key, source, write_meta) :: :ok | {:error, term}
  def write({mod, opts}, key, source, meta), do: mod.write(opts, key, source, meta)

  @doc "Reads the raw bytes stored under `key`."
  @spec read(t, key) :: {:ok, binary, read_meta} | {:error, :not_found | term}
  def read({mod, opts}, key), do: mod.read(opts, key)

  @doc "Deletes `key`. Deleting a missing key is `:ok`."
  @spec delete(t, key) :: :ok | {:error, term}
  def delete({mod, opts}, key), do: mod.delete(opts, key)

  @doc "Lists the keys starting with `prefix`, sorted."
  @spec list(t, String.t()) :: {:ok, [key]} | {:error, term}
  def list({mod, opts}, prefix), do: mod.list(opts, prefix)

  @doc """
  Checks that `key` is a relative path without empty, `.` or `..` segments,
  segments named like a temporary file (`.<name>.tmp`), whitespace, control
  characters or the URL-sensitive characters `?`, `#` and `%`.

      iex> SiteMaps.Adapter.validate_key("posts/sitemap1.xml")
      :ok
      iex> SiteMaps.Adapter.validate_key("/sitemap.xml")
      {:error, :invalid_key}
      iex> SiteMaps.Adapter.validate_key("sitemap.xml?v=1")
      {:error, :invalid_key}
  """
  @spec validate_key(term) :: :ok | {:error, :invalid_key}
  def validate_key(key) when is_binary(key) and key != "" do
    if Regex.match?(~r/[\s\x00-\x1f\x7f?#%]/, key) or Enum.any?(String.split(key, "/"), &invalid_segment?/1) do
      {:error, :invalid_key}
    else
      :ok
    end
  end

  def validate_key(_key), do: {:error, :invalid_key}

  @doc false
  @spec tmp_name?(String.t()) :: boolean
  def tmp_name?(name), do: String.starts_with?(name, ".") and String.ends_with?(name, ".tmp")

  defp invalid_segment?(segment), do: segment in ["", ".", ".."] or tmp_name?(segment)

  @doc """
  Content type derived from the key extension.

      iex> SiteMaps.Adapter.content_type("posts/sitemap1.xml.gz")
      "application/gzip"
      iex> SiteMaps.Adapter.content_type("sitemap.xml")
      "application/xml"
  """
  @spec content_type(key) :: String.t()
  def content_type(key) do
    case Path.extname(key) do
      ".gz" -> "application/gzip"
      ".xml" -> "application/xml"
      ".xsl" -> "text/xsl"
      ".txt" -> "text/plain"
      _ -> "application/octet-stream"
    end
  end
end
