defmodule SiteMaps.LocationTest do
  use ExUnit.Case, async: true

  alias SiteMaps.{Config, Location, Process}

  @gz Config.new!(url: "https://acme.test/sitemap.xml.gz", adapter: SiteMaps.Adapters.Noop)
  @xml Config.new!(url: "https://acme.test/sitemap.xml", adapter: SiteMaps.Adapters.Noop)

  defp family(config, location, args \\ %{}), do: Location.family(config, %Process{name: :p, location: location}, args)

  test "processes without location write numbered files named after the process next to the index" do
    assert Location.key(family(@gz, nil), 1) == "sitemap_p1.xml.gz"
    assert Location.key(family(@xml, nil), 2) == "sitemap_p2.xml"
  end

  test "separates the counter from file names ending in a digit" do
    family = family(@xml, "posts-%{month}.xml", %{month: 1})

    assert Location.key(family, 11) == "posts-1-11.xml"
    assert Location.member?(family, "posts-1-11.xml")
    refute Location.member?(family, "posts-11-1.xml")
    refute Location.member?(family, "posts-111.xml")
  end

  test "builds a pattern matching every execution of a process" do
    process = %Process{name: :p, location: "posts/%{year}-%{month}/sitemap.xml"}
    pattern = Location.pattern(@gz, process)

    assert Regex.match?(pattern, "posts/2026-3/sitemap12.xml.gz")
    refute Regex.match?(pattern, "posts/2026-3/sitemap12.xml")
    refute Regex.match?(pattern, "posts/2026-3/x/sitemap1.xml.gz")
    assert Regex.match?(Location.pattern(@gz, %Process{name: :static}), "sitemap_static3.xml.gz")
  end

  test "interpolates arguments and follows the index compression" do
    family = family(@gz, "posts/%{year}-%{month}/sitemap.xml", %{year: 2026, month: 3})

    assert family == %Location{dir: "posts/2026-3/", stem: "sitemap", ext: ".xml.gz"}
    assert Location.key(family, 12) == "posts/2026-3/sitemap12.xml.gz"
    assert Location.key(family(@xml, "news.xml.gz"), 1) == "news1.xml"
  end

  test "appends a file name to directories and strips leading slashes" do
    assert Location.key(family(@xml, "/posts/"), 1) == "posts/sitemap1.xml"
    assert Location.key(family(@xml, "posts"), 1) == "posts/sitemap1.xml"
    assert Location.key(family(@xml, "/"), 1) == "sitemap1.xml"
  end

  test "rejects locations outside the index directory or with unknown arguments" do
    assert_raise ArgumentError, ~r/inside the index directory/, fn -> family(@xml, "../x/sitemap.xml") end
    assert_raise ArgumentError, ~r/must be a path segment/, fn -> family(@xml, "%{dir}/s.xml", %{dir: ".."}) end
    assert_raise ArgumentError, ~r/must be a path segment/, fn -> family(@xml, "%{dir}/s.xml", %{dir: "a/b"}) end
    assert_raise ArgumentError, ~r/inside the index directory/, fn -> family(@xml, "https://x.test/s.xml") end
    assert_raise ArgumentError, ~r/unknown argument %\{year\}/, fn -> family(@xml, "%{year}/s.xml") end
  end

  test "recognizes the members of a family" do
    family = family(@gz, "posts/%{year}/sitemap.xml", %{year: 2026})

    assert Location.member?(family, "posts/2026/sitemap1.xml.gz")
    assert Location.member?(family, "posts/2026/sitemap120.xml.gz")
    refute Location.member?(family, "posts/2026/sitemap.xml.gz")
    refute Location.member?(family, "posts/2026/sitemap1.xml")
    refute Location.member?(family, "posts/2026/x/sitemap1.xml.gz")
    refute Location.member?(family, "posts/20261/sitemap1.xml.gz")
    refute Location.member?(family(@gz, nil), "sitemap.xml.gz")
    assert Location.member?(family(@gz, nil), "sitemap_p7.xml.gz")
  end
end
