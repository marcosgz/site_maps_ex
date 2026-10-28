defmodule Mix.Tasks.Sitemaps do
  @shortdoc "Generates the sitemaps (all months of the year)"
  @moduledoc @shortdoc

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    SiteMaps.Telemetry.attach_default_logger()

    {:ok, result} = SingleSite.Sitemaps.backfill()
    Mix.shell().info("#{result.links} links in #{length(result.files)} files → #{result.index}")
  end
end
