defmodule SiteMaps.AdapterTest do
  use ExUnit.Case, async: true

  doctest SiteMaps.Adapter

  test "content_type/1 falls back to octet-stream" do
    assert SiteMaps.Adapter.content_type("robots.txt") == "text/plain"
    assert SiteMaps.Adapter.content_type("sitemap.xsl") == "text/xsl"
    assert SiteMaps.Adapter.content_type("archive") == "application/octet-stream"
  end
end
