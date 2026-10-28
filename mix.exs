defmodule SiteMaps.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/marcosgz/site_maps_ex"

  def project do
    [
      app: :site_maps,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Sitemap generation for Elixir: streaming, parallel, incremental and multi-tenant",
      source_url: @source_url,
      test_coverage: [summary: [threshold: 90]],
      dialyzer: [plt_add_apps: [:mix, :ex_aws, :ex_aws_s3, :oban], plt_local_path: "priv/plts"],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib priv/xsl .formatter.exs mix.exs README.md CHANGELOG.md LICENSE.txt)
      ],
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"], source_ref: "v#{@version}"]
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  def application do
    [extra_applications: [:logger], mod: {SiteMaps.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:nimble_options, "~> 1.1"},
      {:saxy, "~> 1.6"},
      {:telemetry, "~> 1.3"},
      {:plug, "~> 1.16"},
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},
      {:oban, "~> 2.19", optional: true},
      {:req, "~> 0.5.10 or ~> 0.6", only: :test},
      {:sweet_xml, "~> 0.7", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false}
    ]
  end
end
