defmodule SiteMaps.ProcessTest do
  use ExUnit.Case, async: true

  alias SiteMaps.Process

  @process %Process{
    name: :posts,
    location: "posts/%{year}/sitemap.xml",
    args: [year: :integer, slug: :string, day: :date, draft: :boolean],
    defaults: [year: 2026, slug: &__MODULE__.default_slug/0, day: ~D[2026-01-01], draft: false]
  }

  def default_slug, do: "all"

  test "fills defaults, evaluating functions" do
    assert Process.build_args(@process, []) == %{year: 2026, slug: "all", day: ~D[2026-01-01], draft: false}
  end

  test "casts string values from the CLI or job arguments" do
    args = Process.build_args(@process, %{"year" => "2024", "day" => "2024-02-29", "draft" => "true"})

    assert args == %{year: 2024, slug: "all", day: ~D[2024-02-29], draft: true}
  end

  test "rejects unknown, missing and invalid arguments" do
    assert_raise ArgumentError, ~r/unknown argument :month/, fn -> Process.build_args(@process, month: 1) end
    assert_raise ArgumentError, ~r/invalid integer "20x"/, fn -> Process.build_args(@process, year: "20x") end
    assert_raise ArgumentError, ~r/invalid date/, fn -> Process.build_args(@process, day: "yesterday") end

    assert_raise ArgumentError, ~r/missing argument :year/, fn ->
      Process.build_args(%Process{name: :p, args: [year: :integer]}, [])
    end
  end

  test "is dynamic when it declares arguments" do
    assert Process.dynamic?(@process)
    refute Process.dynamic?(%Process{name: :static})
  end
end
