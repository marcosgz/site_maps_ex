defmodule SiteMaps.FakeS3 do
  @moduledoc """
  In-memory S3 implemented as a Plug, used with `Req.Test` so the S3 and R2
  adapters run offline.

      store = SiteMaps.FakeS3.start!()
      Req.Test.stub(SiteMaps.FakeS3, {SiteMaps.FakeS3, store})

  Supports path-style PutObject, GetObject, DeleteObject, ListObjectsV2 (with
  pagination of `page_size` keys) and multipart uploads. Every request is
  recorded and returned by `requests/1`.
  """

  @behaviour Plug

  import Plug.Conn

  @doc "Starts a store linked to the caller. `page_size` sets the ListObjectsV2 page size."
  def start!(opts \\ []) do
    state = %{
      objects: %{},
      uploads: %{},
      requests: [],
      page_size: Keyword.get(opts, :page_size, 1000),
      fail: nil
    }

    {:ok, pid} = Agent.start_link(fn -> state end)
    pid
  end

  @doc "Requests received so far, oldest first."
  def requests(store), do: Agent.get(store, &Enum.reverse(&1.requests))

  @doc "Stored objects as `%{{bucket, key} => %{body, headers, last_modified}}`."
  def objects(store), do: Agent.get(store, & &1.objects)

  @doc "Makes every following request answer with `status`."
  def fail_with(store, status), do: Agent.update(store, &%{&1 | fail: status})

  @impl true
  def init(store), do: store

  @impl true
  def call(conn, store) do
    {:ok, body, conn} = read_full_body(conn, "")
    conn = fetch_query_params(conn)
    {bucket, key} = bucket_and_key(conn.request_path)

    request = %{
      method: conn.method,
      host: conn.host,
      path: conn.request_path,
      query: conn.query_params,
      headers: conn.req_headers,
      body: body
    }

    Agent.update(store, &%{&1 | requests: [request | &1.requests]})

    case Agent.get(store, & &1.fail) do
      nil -> handle(conn, store, bucket, key, body)
      status -> send_resp(conn, status, error_xml("InternalError"))
    end
  end

  defp handle(%{method: "PUT", query_params: %{"uploadId" => id, "partNumber" => n}} = conn, store, _bucket, _key, body) do
    etag = ~s("#{Base.encode16(:crypto.hash(:md5, body), case: :lower)}")

    Agent.update(store, fn state ->
      update_in(state.uploads[id].parts, &Map.put(&1, String.to_integer(n), body))
    end)

    conn |> put_resp_header("etag", etag) |> send_resp(200, "")
  end

  defp handle(%{method: "PUT"} = conn, store, bucket, key, body) do
    put(store, bucket, key, body, conn.req_headers)
    conn |> put_resp_header("etag", ~s("etag")) |> send_resp(200, "")
  end

  defp handle(%{method: "POST", query_params: %{"uploads" => _}} = conn, store, bucket, key, _body) do
    id = Integer.to_string(System.unique_integer([:positive]))

    Agent.update(store, fn state ->
      put_in(state.uploads[id], %{bucket: bucket, key: key, headers: conn.req_headers, parts: %{}})
    end)

    xml(conn, 200, """
    <?xml version="1.0" encoding="UTF-8"?>
    <InitiateMultipartUploadResult><Bucket>#{bucket}</Bucket><Key>#{key}</Key><UploadId>#{id}</UploadId></InitiateMultipartUploadResult>
    """)
  end

  defp handle(%{method: "POST", query_params: %{"uploadId" => id}} = conn, store, bucket, key, _body) do
    upload = Agent.get_and_update(store, &pop_in(&1.uploads[id]))
    data = upload.parts |> Enum.sort() |> Enum.map_join(&elem(&1, 1))
    put(store, bucket, key, data, upload.headers)

    xml(conn, 200, """
    <?xml version="1.0" encoding="UTF-8"?>
    <CompleteMultipartUploadResult><Bucket>#{bucket}</Bucket><Key>#{key}</Key></CompleteMultipartUploadResult>
    """)
  end

  defp handle(%{method: "DELETE", query_params: %{"uploadId" => id}} = conn, store, _bucket, _key, _body) do
    Agent.update(store, &%{&1 | uploads: Map.delete(&1.uploads, id)})
    send_resp(conn, 204, "")
  end

  defp handle(%{method: "DELETE"} = conn, store, bucket, key, _body) do
    Agent.update(store, &%{&1 | objects: Map.delete(&1.objects, {bucket, key})})
    send_resp(conn, 204, "")
  end

  defp handle(%{method: "GET", query_params: %{"list-type" => "2"} = params} = conn, store, bucket, _key, _body) do
    prefix = Map.get(params, "prefix", "")
    start = Map.get(params, "continuation-token", "")
    %{objects: objects, page_size: page_size} = Agent.get(store, & &1)

    keys =
      for {{^bucket, key}, _} <- objects, String.starts_with?(key, prefix), key > start, do: key

    {page, rest} = keys |> Enum.sort() |> Enum.split(page_size)
    truncated = rest != []
    contents = Enum.map_join(page, &"<Contents><Key>#{escape(&1)}</Key><Size>1</Size></Contents>")
    token = if truncated, do: "<NextContinuationToken>#{escape(List.last(page))}</NextContinuationToken>", else: ""

    xml(conn, 200, """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult><Name>#{bucket}</Name><Prefix>#{escape(prefix)}</Prefix><KeyCount>#{length(page)}</KeyCount><IsTruncated>#{truncated}</IsTruncated>#{contents}#{token}</ListBucketResult>
    """)
  end

  defp handle(%{method: "GET"} = conn, store, bucket, key, _body) do
    case Agent.get(store, &Map.get(&1.objects, {bucket, key})) do
      nil ->
        xml(conn, 404, error_xml("NoSuchKey"))

      object ->
        object.headers
        |> Enum.filter(fn {name, _} ->
          name in ["content-type", "cache-control"] or String.starts_with?(name, "x-amz-meta-")
        end)
        |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
        |> put_resp_header("last-modified", Calendar.strftime(object.last_modified, "%a, %d %b %Y %H:%M:%S GMT"))
        |> send_resp(200, object.body)
    end
  end

  defp put(store, bucket, key, body, headers) do
    object = %{body: body, headers: headers, last_modified: DateTime.utc_now(:second)}
    Agent.update(store, &%{&1 | objects: Map.put(&1.objects, {bucket, key}, object)})
  end

  defp bucket_and_key(path) do
    [bucket | rest] = path |> String.trim_leading("/") |> String.split("/")
    {URI.decode(bucket), Enum.map_join(rest, "/", &URI.decode/1)}
  end

  defp read_full_body(conn, acc) do
    case read_body(conn) do
      {:ok, data, conn} -> {:ok, acc <> data, conn}
      {:more, data, conn} -> read_full_body(conn, acc <> data)
    end
  end

  defp xml(conn, status, body) do
    conn |> put_resp_content_type("application/xml") |> send_resp(status, body)
  end

  defp error_xml(code) do
    ~s(<?xml version="1.0" encoding="UTF-8"?><Error><Code>#{code}</Code><Message>#{code}</Message></Error>)
  end

  defp escape(text) do
    text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  end
end
