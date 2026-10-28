defmodule SiteMaps.Plug do
  @moduledoc """
  Serves generated sitemaps and the built-in XSL stylesheets.

      plug SiteMaps.Plug,
        sitemaps: &MyAppWeb.Sitemaps.for_conn/1,
        aliases: %{"/sitemap.xml" => "/sitemaps/sitemap.xml.gz"}

  Works in an endpoint, a pipeline or behind a router `forward`. Requests that are not sitemap files
  of the resolved module pass through untouched, so the plug can sit in front of the rest of the app.

  ## Options

    * `:sitemaps` - `{module, context}`, or a function receiving the conn and returning
      `{module, context}` or `nil` (pass through). Use a remote capture (`&Mod.fun/1`) when the plug
      is initialized at compile time. Required.
    * `:aliases` - map of request path to the path to serve, e.g. `%{"/sitemap.xml" => "/sitemap.xml.gz"}`.
      An `.xml` path aliased to an `.xml.gz` file is served uncompressed.
    * `:x_robots_tag` - `x-robots-tag` header (default `"noindex, follow"`, `nil` to omit)
    * `:cache_control` - `cache-control` header. For sitemaps it defaults to the configured
      `cache_control`, and the header is left out when both are `nil`. Stylesheets use this option
      when given, otherwise `"public, max-age=3600"`.
    * `:stylesheet_paths` - `{urlset_path, index_path}` serving the built-in stylesheets
      (default `{"/_sitemap-stylesheet.xsl", "/_sitemap-index-stylesheet.xsl"}`, `nil` to disable).
      Point `xsl_stylesheet_url`/`xsl_index_stylesheet_url` at them.

  The request path must be inside the directory of the configured sitemap URL; the file key is the
  percent-decoded path relative to it. Keys failing `SiteMaps.Adapter.validate_key/1` are rejected.
  Only `.xml` and `.xml.gz` files are served. A `.xml` request for a missing file falls back to its
  `.xml.gz` version, decompressed, when the sitemaps are gzipped.

  Requests with an `if-modified-since` header at or after the file `last_modified` (compared in whole
  seconds) get a `304 Not Modified`. `HEAD` requests get the `GET` headers without decompressing the
  file; `content-length` is omitted when the file would be decompressed.
  """

  @behaviour Plug

  import Plug.Conn

  alias SiteMaps.Config

  require Logger

  @urlset_xsl_path Path.join([__DIR__, "..", "..", "priv", "xsl", "sitemap.xsl"]) |> Path.expand()
  @index_xsl_path Path.join([__DIR__, "..", "..", "priv", "xsl", "sitemap_index.xsl"]) |> Path.expand()
  @external_resource @urlset_xsl_path
  @external_resource @index_xsl_path
  @urlset_xsl File.read!(@urlset_xsl_path)
  @index_xsl File.read!(@index_xsl_path)

  @default_stylesheet_paths {"/_sitemap-stylesheet.xsl", "/_sitemap-index-stylesheet.xsl"}
  @default_cache_control "public, max-age=3600"

  @doc "The built-in urlset XSL stylesheet."
  @spec urlset_xsl() :: String.t()
  def urlset_xsl, do: @urlset_xsl

  @doc "The built-in sitemap index XSL stylesheet."
  @spec index_xsl() :: String.t()
  def index_xsl, do: @index_xsl

  @impl Plug
  def init(opts) do
    sitemaps = Keyword.fetch!(opts, :sitemaps)

    unless match?({mod, _} when is_atom(mod), sitemaps) or is_function(sitemaps, 1) do
      raise ArgumentError, "expected :sitemaps to be {module, context} or a 1-arity function, got: #{inspect(sitemaps)}"
    end

    %{
      sitemaps: sitemaps,
      aliases: Keyword.get(opts, :aliases, %{}),
      x_robots_tag: Keyword.get(opts, :x_robots_tag, "noindex, follow"),
      cache_control: Keyword.get(opts, :cache_control),
      stylesheet_paths: Keyword.get(opts, :stylesheet_paths, @default_stylesheet_paths)
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD"] do
    path = Map.get(opts.aliases, conn.request_path, conn.request_path)

    case stylesheet(path, opts.stylesheet_paths) do
      nil -> maybe_serve_sitemap(conn, path, opts)
      xsl -> serve_stylesheet(conn, xsl, opts)
    end
  end

  def call(conn, _opts), do: conn

  defp stylesheet(path, {path, _}), do: @urlset_xsl
  defp stylesheet(path, {_, path}), do: @index_xsl
  defp stylesheet(_path, _paths), do: nil

  defp serve_stylesheet(conn, xsl, opts) do
    conn
    |> put_resp_content_type("text/xsl")
    |> put_resp_header("cache-control", opts.cache_control || @default_cache_control)
    |> send_resp(200, xsl)
    |> halt()
  end

  defp maybe_serve_sitemap(conn, path, opts) do
    with true <- String.ends_with?(path, [".xml", ".xml.gz"]),
         {module, context} <- resolve_sitemaps(conn, opts.sitemaps),
         %Config{} = config <- SiteMaps.config!(module, context),
         {:ok, key} <- key(config, path),
         {:ok, body, meta, gzipped?} <- read(config, key) do
      send_sitemap(
        conn,
        body,
        meta,
        gzipped? and not String.ends_with?(conn.request_path, ".gz"),
        gzipped?,
        config,
        opts
      )
    else
      {:error, reason} when reason != :not_found ->
        Logger.warning("SiteMaps.Plug could not read #{conn.request_path}: #{inspect(reason)}")
        conn

      _ ->
        conn
    end
  end

  defp resolve_sitemaps(conn, fun) when is_function(fun, 1), do: fun.(conn)
  defp resolve_sitemaps(_conn, sitemaps), do: sitemaps

  defp key(%Config{root_uri: %URI{path: root}}, path) do
    case String.replace_prefix(path, root, "") do
      ^path -> :error
      "" -> :error
      relative -> relative |> String.split("/") |> decode_segments([])
    end
  end

  defp decode_segments([], acc) do
    key = acc |> Enum.reverse() |> Enum.join("/")
    if SiteMaps.Adapter.validate_key(key) == :ok, do: {:ok, key}, else: :error
  end

  defp decode_segments([segment | rest], acc) do
    decoded = URI.decode(segment)

    if String.contains?(decoded, ["/", "\\"]) do
      :error
    else
      decode_segments(rest, [decoded | acc])
    end
  end

  defp read(%Config{adapter: adapter} = config, key) do
    case SiteMaps.Adapter.read(adapter, key) do
      {:ok, body, meta} ->
        {:ok, body, meta, String.ends_with?(key, ".gz")}

      {:error, :not_found} when config.gzip? ->
        if String.ends_with?(key, ".xml"), do: read_gzipped(adapter, key <> ".gz"), else: {:error, :not_found}

      error ->
        error
    end
  end

  defp read_gzipped(adapter, key) do
    with {:ok, body, meta} <- SiteMaps.Adapter.read(adapter, key), do: {:ok, body, meta, true}
  end

  defp send_sitemap(conn, body, meta, decompress?, gzipped?, config, opts) do
    content_type = content_type(gzipped? and not decompress?)

    cond do
      not_modified?(conn, meta[:last_modified]) ->
        conn |> put_sitemap_headers(meta, config, opts) |> send_resp(304, "") |> halt()

      conn.method == "HEAD" and decompress? ->
        conn
        |> put_sitemap_headers(meta, config, opts)
        |> put_resp_header("content-type", content_type)
        |> send_chunked(200)
        |> halt()

      true ->
        send_body(conn, body, content_type, decompress?, meta, config, opts)
    end
  end

  defp send_body(conn, body, content_type, decompress?, meta, config, opts) do
    case if(decompress?, do: gunzip(body), else: {:ok, body}) do
      {:ok, body} ->
        conn
        |> put_sitemap_headers(meta, config, opts)
        |> put_resp_header("content-type", content_type)
        |> send_resp(200, body)
        |> halt()

      :error ->
        Logger.warning("SiteMaps.Plug could not decompress #{conn.request_path}")
        conn
    end
  end

  defp put_sitemap_headers(conn, meta, config, opts) do
    conn
    |> put_cache_control(opts.cache_control || config.cache_control)
    |> put_optional_header("x-robots-tag", opts.x_robots_tag)
    |> put_optional_header("last-modified", http_date(meta[:last_modified]))
  end

  defp not_modified?(conn, %DateTime{} = last_modified) do
    with [value | _] <- get_req_header(conn, "if-modified-since"),
         %DateTime{} = since <- parse_http_date(value) do
      DateTime.compare(DateTime.truncate(last_modified, :second), since) != :gt
    else
      _ -> false
    end
  end

  defp not_modified?(_conn, _last_modified), do: false

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp parse_http_date(value) do
    with [_, day, month, year, time] <- Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/, value),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, naive} <-
           NaiveDateTime.from_iso8601("#{year}-#{String.pad_leading("#{month + 1}", 2, "0")}-#{day} #{time}") do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp content_type(true), do: "application/gzip"
  defp content_type(false), do: "application/xml; charset=utf-8"

  defp gunzip(body) do
    {:ok, :zlib.gunzip(body)}
  rescue
    ErlangError -> :error
  end

  defp put_cache_control(conn, nil), do: delete_resp_header(conn, "cache-control")
  defp put_cache_control(conn, value), do: put_resp_header(conn, "cache-control", value)

  defp put_optional_header(conn, _name, nil), do: conn
  defp put_optional_header(conn, name, value), do: put_resp_header(conn, name, value)

  defp http_date(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp http_date(_), do: nil
end
