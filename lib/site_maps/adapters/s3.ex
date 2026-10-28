defmodule SiteMaps.Adapters.S3 do
  @schema NimbleOptions.new!(
            bucket: [type: :string, required: true, doc: "Bucket name."],
            prefix: [type: :string, default: "", doc: "Key prefix inside the bucket."],
            region: [type: :string, doc: "Bucket region. Defaults to the ExAws configuration."],
            endpoint: [
              type: :string,
              doc:
                "Base URL of an S3-compatible service, such as `\"http://localhost:9000\"`. " <>
                  "Sets scheme, host and port of the ExAws configuration."
            ],
            access_key_id: [type: :string, doc: "Defaults to the ExAws configuration."],
            secret_access_key: [type: :string, doc: "Defaults to the ExAws configuration."],
            security_token: [type: :string, doc: "Session token for temporary credentials."],
            acl: [
              type: {:or, [:atom, :string]},
              doc:
                "Canned ACL such as `:public_read`. When `nil` no `x-amz-acl` header is sent, " <>
                  "which is required by buckets with ACLs disabled."
            ],
            cache_control: [
              type: :string,
              doc: "Overrides the `cache_control` given by the sitemap configuration."
            ],
            storage_class: [type: {:or, [:atom, :string]}, doc: "Storage class, such as `:standard_ia`."],
            virtual_host: [
              type: :boolean,
              doc:
                "Use virtual-hosted style (`bucket.host`) instead of path style. " <>
                  "Defaults to the ExAws configuration."
            ],
            multipart_threshold: [
              type: :pos_integer,
              default: 8 * 1024 * 1024,
              doc: "Files larger than this many bytes are uploaded in multiple parts."
            ],
            part_size: [
              type: {:custom, __MODULE__, :validate_part_size, []},
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
  Stores sitemaps in AWS S3 or any S3-compatible service (MinIO, DigitalOcean
  Spaces, Wasabi, Ceph, Google Cloud Storage interoperability).

  Requires the optional dependencies `ex_aws`, `ex_aws_s3` and an HTTP client
  supported by ExAws, such as `req`:

      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:req, "~> 0.5"}

      # config/config.exs
      config :ex_aws, http_client: ExAws.Request.Req

  Example:

      adapter: {SiteMaps.Adapters.S3, bucket: "sitemaps", prefix: "acme", region: "us-east-1"}

      adapter:
        {SiteMaps.Adapters.S3,
         bucket: "sitemaps",
         endpoint: "http://minio:9000",
         access_key_id: "minio",
         secret_access_key: "minio123"}

  Files up to `multipart_threshold` are sent with a single `PutObject`. Larger
  files are streamed from disk in `part_size` parts, so memory stays bounded.
  The `last_modified` given by the writer is kept in the
  `x-amz-meta-given-last-modified` metadata header and returned by `read/2`.

  For Cloudflare R2 use `SiteMaps.Adapters.R2`.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @behaviour SiteMaps.Adapter

  @compile {:no_warn_undefined, [ExAws, ExAws.S3]}

  @meta_last_modified "given-last-modified"
  @min_part_size 5 * 1024 * 1024

  @doc false
  def schema, do: @schema

  @doc false
  def validate_part_size(size) when is_integer(size) and size >= @min_part_size, do: {:ok, size}

  def validate_part_size(size),
    do: {:error, "expected an integer of at least #{@min_part_size} bytes, got: #{inspect(size)}"}

  @impl true
  def write(opts, key, source, meta) do
    opts = validate!(opts)

    with :ok <- SiteMaps.Adapter.validate_key(key) do
      upload(opts, object_key(opts, key), source, put_options(opts, key, meta))
    end
  end

  @impl true
  def read(opts, key) do
    opts = validate!(opts)

    with :ok <- SiteMaps.Adapter.validate_key(key) do
      get_object(opts, key)
    end
  end

  @impl true
  def delete(opts, key) do
    opts = validate!(opts)

    with :ok <- SiteMaps.Adapter.validate_key(key) do
      case request(ExAws.S3.delete_object(opts[:bucket], object_key(opts, key)), opts) do
        {:ok, _} -> :ok
        {:error, {:http_error, 404, _}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def list(opts, prefix) do
    opts = validate!(opts)
    root = root_prefix(opts)

    with {:ok, keys} <- list_pages(opts, root <> prefix, nil, []) do
      {:ok, keys |> Enum.map(&String.replace_prefix(&1, root, "")) |> Enum.sort()}
    end
  end

  defp get_object(opts, key) do
    case request(ExAws.S3.get_object(opts[:bucket], object_key(opts, key)), opts) do
      {:ok, %{body: body, headers: headers}} ->
        meta = %{
          content_type: header(headers, "content-type"),
          last_modified: last_modified(headers)
        }

        {:ok, body, meta}

      {:error, {:http_error, 404, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate!(opts) do
    unless Code.ensure_loaded?(ExAws.S3) do
      raise RuntimeError,
            "#{inspect(__MODULE__)} requires the optional dependencies :ex_aws and :ex_aws_s3"
    end

    NimbleOptions.validate!(opts, @schema)
  end

  defp upload(opts, object, {:file, path}, headers) do
    threshold = opts[:multipart_threshold]

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > threshold ->
        multipart_upload(opts, object, path, headers)

      {:ok, _stat} ->
        with {:ok, body} <- File.read(path), do: put_object(opts, object, body, headers)

      error ->
        error
    end
  end

  defp upload(opts, object, iodata, headers) do
    put_object(opts, object, IO.iodata_to_binary(iodata), headers)
  end

  defp put_object(opts, object, body, headers) do
    case request(ExAws.S3.put_object(opts[:bucket], object, body, headers), opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp multipart_upload(opts, object, path, headers) do
    init = ExAws.S3.initiate_multipart_upload(opts[:bucket], object, headers)

    with {:ok, %{body: body}} <- request(raw(init), opts),
         {:ok, upload_id} <- xml_text(body, "UploadId") do
      try do
        with {:ok, parts} <- upload_parts(opts, object, path, upload_id),
             :ok <- complete_upload(opts, object, upload_id, parts) do
          :ok
        else
          error ->
            abort_upload(opts, object, upload_id)
            error
        end
      catch
        kind, reason ->
          abort_upload(opts, object, upload_id)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp abort_upload(opts, object, upload_id) do
    request(ExAws.S3.abort_multipart_upload(opts[:bucket], object, upload_id), opts)
  end

  defp upload_parts(opts, object, path, upload_id) do
    path
    |> File.stream!(opts[:part_size])
    |> Stream.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {chunk, number}, {:ok, parts} ->
      op = ExAws.S3.upload_part(opts[:bucket], object, upload_id, number, chunk)

      case request(op, opts) do
        {:ok, %{headers: headers}} -> {:cont, {:ok, [{number, header(headers, "etag")} | parts]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp complete_upload(opts, object, upload_id, parts) do
    op = ExAws.S3.complete_multipart_upload(opts[:bucket], object, upload_id, parts)

    with {:ok, %{body: body}} <- request(raw(op), opts) do
      case xml_root(body) do
        {:ok, {"Error", _, _} = error} -> {:error, {:s3_error, child_text(error, "Code")}}
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp list_pages(opts, prefix, token, acc) do
    params = [prefix: prefix] ++ if(token, do: [continuation_token: token], else: [])
    op = ExAws.S3.list_objects_v2(opts[:bucket], params)

    with {:ok, %{body: body}} <- request(raw(op), opts),
         {:ok, root} <- xml_root(body) do
      keys = for {"Contents", _, _} = node <- children(root), do: child_text(node, "Key")
      acc = keys ++ acc

      case {child_text(root, "IsTruncated"), child_text(root, "NextContinuationToken")} do
        {"true", next} when next not in [nil, ""] -> list_pages(opts, prefix, next, acc)
        _ -> {:ok, acc}
      end
    end
  end

  defp raw(op), do: %{op | parser: & &1}

  defp request(op, opts), do: ExAws.request(op, aws_config(opts))

  defp aws_config(opts) do
    endpoint =
      case opts[:endpoint] do
        nil ->
          []

        url ->
          uri = URI.parse(url)
          [scheme: "#{uri.scheme}://", host: uri.host, port: uri.port]
      end

    credentials = Keyword.take(opts, [:region, :access_key_id, :secret_access_key, :security_token])

    endpoint
    |> Keyword.merge(credentials)
    |> Keyword.merge(Keyword.take(opts, [:virtual_host]))
    |> Keyword.merge(opts[:ex_aws])
  end

  defp put_options(opts, key, meta) do
    last_modified =
      case meta[:last_modified] do
        %DateTime{} = time ->
          [{@meta_last_modified, time |> DateTime.truncate(:second) |> DateTime.to_iso8601()}]

        nil ->
          []
      end

    [
      content_type: meta[:content_type] || SiteMaps.Adapter.content_type(key),
      cache_control: opts[:cache_control] || meta[:cache_control],
      meta: last_modified,
      acl: opts[:acl],
      storage_class: opts[:storage_class]
    ]
    |> Enum.reject(fn {_name, value} -> value in [nil, []] end)
  end

  defp root_prefix(opts) do
    case String.trim(opts[:prefix], "/") do
      "" -> ""
      prefix -> prefix <> "/"
    end
  end

  defp object_key(opts, key), do: root_prefix(opts) <> key

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: header_value(value)
    end)
  end

  defp header_value([value | _]), do: value
  defp header_value(value), do: value

  defp last_modified(headers) do
    with nil <- parse_iso8601(header(headers, "x-amz-meta-" <> @meta_last_modified)) do
      parse_http_date(header(headers, "last-modified"))
    end
  end

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _ -> nil
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp parse_http_date(nil), do: nil

  defp parse_http_date(value) do
    with [_, day, month, year, hour, minute, second] <-
           Regex.run(~r/(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})/, value),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(year),
             month + 1,
             String.to_integer(day),
             String.to_integer(hour),
             String.to_integer(minute),
             String.to_integer(second)
           ) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp xml_root(body) do
    case Saxy.SimpleForm.parse_string(body) do
      {:ok, root} -> {:ok, root}
      {:error, reason} -> {:error, {:invalid_xml, reason}}
    end
  end

  defp xml_text(body, name) do
    with {:ok, root} <- xml_root(body) do
      case child_text(root, name) do
        nil -> {:error, {:missing_element, name}}
        text -> {:ok, text}
      end
    end
  end

  defp children({_name, _attrs, children}), do: Enum.filter(children, &is_tuple/1)

  defp child_text(node, name) do
    Enum.find_value(children(node), fn
      {^name, _, content} -> content |> Enum.filter(&is_binary/1) |> Enum.join()
      _ -> nil
    end)
  end
end
