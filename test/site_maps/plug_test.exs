defmodule SiteMaps.PlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  alias SiteMaps.WebFixtures.Sitemaps

  @index ~s(<?xml version="1.0" encoding="UTF-8"?><sitemapindex></sitemapindex>)
  @urlset ~s(<?xml version="1.0" encoding="UTF-8"?><urlset></urlset>)
  @modified ~U[2026-03-01 10:20:30Z]

  defp context(opts \\ []) do
    files =
      Keyword.get(opts, :files, %{
        "sitemap.xml.gz" => {:zlib.gzip(@index), %{content_type: "application/gzip", last_modified: @modified}},
        "posts/2026-03/sitemap1.xml.gz" => {:zlib.gzip(@urlset), %{content_type: "application/gzip"}},
        "plain.xml" => {@urlset, %{content_type: "application/xml"}},
        "broken.xml.gz" => {:error, :timeout},
        "corrupt.xml.gz" => "not gzip",
        "robots.txt" => "nope"
      })

    %{
      url: Keyword.get(opts, :url, "https://acme.com/sitemaps/sitemap.xml.gz"),
      files: files,
      config: Keyword.get(opts, :config, [])
    }
  end

  defp call(path, opts \\ []), do: request(:get, path, opts)

  defp request(method, path, opts \\ []) do
    opts = Keyword.put_new(opts, :sitemaps, {Sitemaps, context()})
    method |> conn(path) |> SiteMaps.Plug.call(SiteMaps.Plug.init(opts))
  end

  defp modified_since_call(method, path, since, context_opts \\ []) do
    method
    |> conn(path)
    |> Plug.Conn.put_req_header("if-modified-since", since)
    |> SiteMaps.Plug.call(SiteMaps.Plug.init(sitemaps: {Sitemaps, context(context_opts)}))
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  describe "init/1" do
    test "requires :sitemaps" do
      assert_raise KeyError, fn -> SiteMaps.Plug.init([]) end
    end

    test "rejects an invalid :sitemaps" do
      assert_raise ArgumentError, ~r/expected :sitemaps/, fn -> SiteMaps.Plug.init(sitemaps: "nope") end
    end
  end

  describe "stylesheets" do
    test "serves the urlset stylesheet" do
      conn = call("/_sitemap-stylesheet.xsl")

      assert conn.status == 200
      assert conn.halted
      assert header(conn, "content-type") =~ "text/xsl"
      assert header(conn, "cache-control") == "public, max-age=3600"
      assert conn.resp_body == SiteMaps.Plug.urlset_xsl()
      assert conn.resp_body =~ "sitemap:urlset/sitemap:url"
      assert conn.resp_body =~ "count(image:image)"
    end

    test "serves the index stylesheet" do
      conn = call("/_sitemap-index-stylesheet.xsl")

      assert conn.status == 200
      assert conn.resp_body == SiteMaps.Plug.index_xsl()
      assert conn.resp_body =~ "sitemap:sitemapindex/sitemap:sitemap"
    end

    test "stylesheets are well-formed XSL" do
      for xsl <- [SiteMaps.Plug.urlset_xsl(), SiteMaps.Plug.index_xsl()] do
        assert {:ok, _} = Saxy.SimpleForm.parse_string(xsl)
        assert xsl =~ ~s(xmlns:xsl="http://www.w3.org/1999/XSL/Transform")
      end
    end

    test "serves stylesheets without resolving the sitemaps" do
      conn = call("/_sitemap-stylesheet.xsl", sitemaps: fn _ -> raise "not resolved" end)
      assert conn.status == 200
    end

    test "custom paths and cache control" do
      opts = [stylesheet_paths: {"/a.xsl", "/b.xsl"}, cache_control: "public, max-age=60"]

      assert call("/a.xsl", opts).resp_body == SiteMaps.Plug.urlset_xsl()
      assert call("/b.xsl", opts).resp_body == SiteMaps.Plug.index_xsl()
      assert header(call("/a.xsl", opts), "cache-control") == "public, max-age=60"
      refute call("/_sitemap-stylesheet.xsl", opts).halted
    end

    test "disabled with nil" do
      conn = call("/_sitemap-stylesheet.xsl", stylesheet_paths: nil)
      refute conn.halted
      assert conn.status == nil
    end
  end

  describe "sitemaps" do
    test "serves a gzipped file as stored" do
      conn = call("/sitemaps/sitemap.xml.gz")

      assert conn.status == 200
      assert conn.halted
      assert header(conn, "content-type") == "application/gzip"
      assert :zlib.gunzip(conn.resp_body) == @index
      assert header(conn, "x-robots-tag") == "noindex, follow"
      assert header(conn, "cache-control") == "public, max-age=3600"
      assert header(conn, "last-modified") == "Sun, 01 Mar 2026 10:20:30 GMT"
    end

    test "serves nested files" do
      conn = call("/sitemaps/posts/2026-03/sitemap1.xml.gz")

      assert conn.status == 200
      assert :zlib.gunzip(conn.resp_body) == @urlset
      assert header(conn, "last-modified") == nil
    end

    test "serves plain XML" do
      conn = call("/sitemaps/plain.xml")

      assert conn.status == 200
      assert header(conn, "content-type") == "application/xml; charset=utf-8"
      assert conn.resp_body == @urlset
    end

    test "serves HEAD requests with the GET headers" do
      get = call("/sitemaps/sitemap.xml.gz")
      head = request(:head, "/sitemaps/sitemap.xml.gz")

      assert head.status == 200
      assert head.halted

      for name <- ["content-type", "cache-control", "x-robots-tag", "last-modified"] do
        assert header(head, name) == header(get, name)
      end
    end

    test "HEAD of a decompressed file sends the GET headers without decompressing" do
      get = call("/sitemaps/posts/2026-03/sitemap1.xml")
      head = request(:head, "/sitemaps/posts/2026-03/sitemap1.xml")

      assert head.status == 200
      assert head.halted
      assert head.resp_body == ""

      for name <- ["content-type", "cache-control", "x-robots-tag"] do
        assert header(head, name) == header(get, name)
      end

      corrupt = request(:head, "/sitemaps/corrupt.xml")
      assert corrupt.status == 200
      assert header(corrupt, "content-type") == "application/xml; charset=utf-8"
    end

    test "answers 304 when not modified since" do
      for since <- ["Sun, 01 Mar 2026 10:20:30 GMT", "Mon, 02 Mar 2026 00:00:00 GMT"], method <- [:get, :head] do
        conn = modified_since_call(method, "/sitemaps/sitemap.xml.gz", since)

        assert conn.status == 304
        assert conn.halted
        assert conn.resp_body == ""
        assert header(conn, "last-modified") == "Sun, 01 Mar 2026 10:20:30 GMT"
        assert header(conn, "cache-control") == "public, max-age=3600"
      end
    end

    test "compares if-modified-since with second precision" do
      files = %{"plain.xml" => {@urlset, %{last_modified: ~U[2026-03-01 10:20:30.900Z]}}}
      conn = modified_since_call(:get, "/sitemaps/plain.xml", "Sun, 01 Mar 2026 10:20:30 GMT", files: files)

      assert conn.status == 304
    end

    test "serves the file when modified since or the header is unusable" do
      for since <- ["Sun, 01 Mar 2026 10:20:29 GMT", "garbage", "Sunday, 01-Mar-26 10:20:30 GMT"] do
        conn = modified_since_call(:get, "/sitemaps/sitemap.xml.gz", since)

        assert conn.status == 200, since
        assert :zlib.gunzip(conn.resp_body) == @index
      end

      conn = modified_since_call(:get, "/sitemaps/posts/2026-03/sitemap1.xml.gz", "Mon, 02 Mar 2026 00:00:00 GMT")
      assert conn.status == 200
    end

    test "content type follows the key, not the body" do
      files = %{"a.xml.gz" => "<x/>", "b.xml" => :zlib.gzip(@urlset)}
      sitemaps = {Sitemaps, context(files: files)}

      assert header(call("/sitemaps/a.xml.gz", sitemaps: sitemaps), "content-type") == "application/gzip"
      assert header(call("/sitemaps/b.xml", sitemaps: sitemaps), "content-type") == "application/xml; charset=utf-8"
    end

    test "decodes percent-encoded keys" do
      sitemaps = {Sitemaps, context(files: %{"sitemap~one.xml" => @urlset})}
      conn = call("/sitemaps/sitemap%7Eone.xml", sitemaps: sitemaps)

      assert conn.status == 200
      assert conn.resp_body == @urlset
      assert_received {:adapter_read, "sitemap~one.xml"}
    end

    test "last-modified of a non-UTC datetime is converted to GMT" do
      modified = %DateTime{
        year: 2026,
        month: 3,
        day: 1,
        hour: 7,
        minute: 20,
        second: 30,
        microsecond: {0, 0},
        time_zone: "America/Sao_Paulo",
        zone_abbr: "-03",
        utc_offset: -10_800,
        std_offset: 0
      }

      sitemaps = {Sitemaps, context(files: %{"plain.xml" => {@urlset, %{last_modified: modified}}})}

      assert header(call("/sitemaps/plain.xml", sitemaps: sitemaps), "last-modified") == "Sun, 01 Mar 2026 10:20:30 GMT"
    end

    test "falls back to the gzipped file and decompresses it" do
      conn = call("/sitemaps/posts/2026-03/sitemap1.xml")

      assert conn.status == 200
      assert header(conn, "content-type") == "application/xml; charset=utf-8"
      assert conn.resp_body == @urlset
    end

    test "does not fall back when the sitemaps are not gzipped" do
      sitemaps = {Sitemaps, context(url: "https://acme.com/sitemaps/sitemap.xml")}
      refute call("/sitemaps/posts/2026-03/sitemap1.xml", sitemaps: sitemaps).halted
    end

    test "an .xml alias of a gzipped file is decompressed" do
      conn = call("/sitemap.xml", aliases: %{"/sitemap.xml" => "/sitemaps/sitemap.xml.gz"})

      assert conn.status == 200
      assert header(conn, "content-type") == "application/xml; charset=utf-8"
      assert conn.resp_body == @index
    end

    test "an .xml.gz alias is served compressed" do
      conn = call("/sitemap.xml.gz", aliases: %{"/sitemap.xml.gz" => "/sitemaps/sitemap.xml.gz"})

      assert header(conn, "content-type") == "application/gzip"
      assert :zlib.gunzip(conn.resp_body) == @index
    end

    test "custom headers" do
      sitemaps = {Sitemaps, context(config: [cache_control: "private"])}

      assert header(call("/sitemaps/plain.xml", sitemaps: sitemaps), "cache-control") == "private"
      assert header(call("/sitemaps/plain.xml", cache_control: "no-cache"), "cache-control") == "no-cache"
      assert header(call("/sitemaps/plain.xml", x_robots_tag: "noindex"), "x-robots-tag") == "noindex"
      assert header(call("/sitemaps/plain.xml", x_robots_tag: nil), "x-robots-tag") == nil
    end

    test "omits cache-control when neither the option nor the config set it" do
      sitemaps = {Sitemaps, context(config: [cache_control: nil])}
      conn = call("/sitemaps/plain.xml", sitemaps: sitemaps)

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "cache-control") == []
    end

    test "sitemaps at the site root" do
      sitemaps = {Sitemaps, context(url: "https://acme.com/sitemap.xml.gz")}
      conn = call("/sitemap.xml.gz", sitemaps: sitemaps)

      assert conn.status == 200
      assert :zlib.gunzip(conn.resp_body) == @index
    end

    test "resolves the sitemaps from the conn" do
      tenants = %{
        "acme.com" => context(url: "https://acme.com/sitemaps/sitemap.xml.gz"),
        "globex.com" =>
          context(url: "https://globex.com/sitemaps/sitemap.xml.gz", files: %{"sitemap.xml.gz" => :zlib.gzip("globex")})
      }

      resolver = fn conn -> if ctx = tenants[conn.host], do: {Sitemaps, ctx} end
      request = fn host -> :get |> conn("/sitemaps/sitemap.xml.gz") |> Map.put(:host, host) end
      opts = SiteMaps.Plug.init(sitemaps: resolver)

      assert :zlib.gunzip(SiteMaps.Plug.call(request.("acme.com"), opts).resp_body) == @index
      assert :zlib.gunzip(SiteMaps.Plug.call(request.("globex.com"), opts).resp_body) == "globex"
      refute SiteMaps.Plug.call(request.("other.com"), opts).halted
    end
  end

  describe "pass through" do
    test "missing files" do
      conn = call("/sitemaps/missing.xml.gz")
      refute conn.halted
      assert conn.status == nil
    end

    test "paths outside the sitemap directory" do
      refute call("/other/sitemap.xml.gz").halted
      refute call("/sitemaps.xml.gz").halted
      refute call("/sitemaps/").halted
    end

    test "path traversal never reaches the adapter" do
      for path <- [
            "/sitemaps/../sitemaps/plain.xml",
            "/sitemaps/./plain.xml",
            "/sitemaps//plain.xml",
            "/sitemaps/%2e%2e/sitemaps/plain.xml",
            "/sitemaps/%2E/plain.xml",
            "/sitemaps/..%2fsitemaps/plain.xml",
            "/sitemaps/..%5csitemaps/plain.xml",
            "/sitemaps/plain%00.xml",
            "/sitemaps/plain%20.xml",
            "/sitemaps/plain%3F.xml",
            "/sitemaps/plain%23.xml",
            "/sitemaps/plain%25.xml"
          ] do
        conn = call(path)
        refute conn.halted, path
        refute_received {:adapter_read, _}, path
      end
    end

    test "non-sitemap files are not resolved" do
      conn = call("/sitemaps/robots.txt", sitemaps: fn _ -> raise "not resolved" end)
      refute conn.halted
    end

    test "other methods" do
      refute request(:post, "/sitemaps/plain.xml").halted
      refute request(:post, "/_sitemap-stylesheet.xsl").halted
    end

    test "a nil resolver result" do
      refute call("/sitemaps/plain.xml", sitemaps: fn _ -> nil end).halted
    end

    test "adapter errors are logged" do
      log = capture_log(fn -> refute call("/sitemaps/broken.xml.gz").halted end)
      assert log =~ "/sitemaps/broken.xml.gz"
      assert log =~ ":timeout"
    end

    test "corrupt gzip is logged" do
      log = capture_log(fn -> refute call("/sitemaps/corrupt.xml").halted end)
      assert log =~ "could not decompress"
    end
  end
end
