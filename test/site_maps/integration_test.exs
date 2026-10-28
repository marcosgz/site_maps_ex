defmodule SiteMaps.IntegrationTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SiteMaps.Generate
  alias SiteMaps.Oban.Worker
  alias SiteMaps.Test.CliSite

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp read(dir, key), do: dir |> Path.join(key) |> File.read!() |> :zlib.gunzip()

  test "mix site_maps.generate writes through the real engine", %{tmp_dir: dir} do
    Generate.run(["SiteMaps.Test.CliSite", "--context", "dir=#{dir}", "--quiet"])

    assert read(dir, "sitemap.xml.gz") =~ "https://cli.test/archive/2026/2026-01-01/sitemap1.xml.gz"

    Generate.run(~w(SiteMaps.Test.CliSite archive --context dir=#{dir} --arg year=2024 --arg day=2024-05-06 --quiet))

    index = read(dir, "sitemap.xml.gz")
    assert index =~ "https://cli.test/archive/2024/2024-05-06/sitemap1.xml.gz"
    assert index =~ "https://cli.test/archive/2026/2026-01-01/sitemap1.xml.gz"
    assert index =~ "https://cli.test/sitemap_static1.xml.gz"
    assert read(dir, "archive/2024/2024-05-06/sitemap1.xml.gz") =~ "<lastmod>2024-05-06</lastmod>"
  end

  test "the Oban worker runs a JSON round-tripped job", %{tmp_dir: dir} do
    changeset = Worker.new_job(CliSite, context: %{dir: dir}, only: [archive: [day: ~D[2025-02-03]]])
    args = changeset.changes.args |> Jason.encode!() |> Jason.decode!()

    assert :ok = Worker.perform(%Oban.Job{args: args})
    assert read(dir, "archive/2026/2025-02-03/sitemap1.xml.gz") =~ "<lastmod>2025-02-03</lastmod>"
    assert read(dir, "sitemap.xml.gz") =~ "archive/2026/2025-02-03/sitemap1.xml.gz"
  end
end
