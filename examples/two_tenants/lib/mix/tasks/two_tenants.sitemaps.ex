defmodule Mix.Tasks.TwoTenants.Sitemaps do
  @shortdoc "Generates the sitemaps of every tenant (all months of the year)"
  @moduledoc @shortdoc

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    SiteMaps.Telemetry.attach_default_logger()

    for tenant <- TwoTenants.Tenants.all() do
      {:ok, result} = TwoTenants.Sitemaps.backfill(tenant)

      Mix.shell().info(
        "#{tenant.slug}: #{result.links} links in #{length(result.files)} files → #{result.index}"
      )
    end
  end
end
