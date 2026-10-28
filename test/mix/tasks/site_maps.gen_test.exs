defmodule Mix.Tasks.SiteMaps.GenTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SiteMaps.Gen

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "writes a single-site module that compiles cleanly", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn -> Gen.run(["GenTestApp.Sitemaps"]) end)

    path = Path.join(tmp_dir, "lib/gen_test_app/sitemaps.ex")
    assert File.exists?(path)
    assert_received {:mix_shell, :info, [_created]}
    assert_received {:mix_shell, :info, [next_steps]}
    assert next_steps =~ ~s(config :site_maps, GenTestApp.Sitemaps, url: "https://example.com/sitemap.xml.gz")
    assert next_steps =~ "mix site_maps.generate GenTestApp.Sitemaps"
    assert next_steps =~ "plug SiteMaps.Plug, sitemaps: {GenTestApp.Sitemaps, %{}}"

    module = compile!(path)
    assert module == GenTestApp.Sitemaps
    refute function_exported?(module, :config, 1)
    assert Enum.map(SiteMaps.processes(module), & &1.name) == [:static, :archive]
    assert module.current_month() == Calendar.strftime(Date.utc_today(), "%Y-%m")

    Application.put_env(:site_maps, module, url: "https://example.com/sitemap.xml.gz")
    on_exit(fn -> Application.delete_env(:site_maps, GenTestApp.Sitemaps) end)
    config = SiteMaps.config!(module, %{})
    assert config.url == "https://example.com/sitemap.xml.gz"
    assert config.adapter == {SiteMaps.Adapters.FileSystem, directory: "priv/sitemaps"}

    today = Date.utc_today()
    archive = Enum.to_list(module.urls(:archive, %{month: module.current_month()}, %{}))
    assert length(archive) == today.day
    assert Enum.all?(archive, &(Date.compare(&1.lastmod, today) != :gt))
    assert module.urls(:archive, %{month: "#{today.year + 1}-01"}, %{}) |> Enum.to_list() == []
  end

  test "writes a multi-site module with --multi", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn -> Gen.run(["GenMultiApp.Sitemaps", "--multi"]) end)

    assert_received {:mix_shell, :info, [_created]}
    assert_received {:mix_shell, :info, [next_steps]}
    assert next_steps =~ "mix site_maps.generate GenMultiApp.Sitemaps --context site=example.com"

    module = compile!(Path.join(tmp_dir, "lib/gen_multi_app/sitemaps.ex"))
    assert module.load_context(%{"site" => "acme.test"}) == %{site: "acme.test"}

    config = SiteMaps.config!(module, %{site: "acme.test"})
    assert config.url == "https://acme.test/sitemap.xml.gz"
    assert config.adapter == {SiteMaps.Adapters.FileSystem, directory: "priv/sitemaps/acme.test"}
  end

  test "keeps an existing file unless forced", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "lib/gen_keep/sitemaps.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "original")

    send(self(), {:mix_shell_input, :yes?, false})
    File.cd!(tmp_dir, fn -> Gen.run(["GenKeep.Sitemaps"]) end)
    assert File.read!(path) == "original"

    File.cd!(tmp_dir, fn -> Gen.run(["GenKeep.Sitemaps", "--force"]) end)
    assert File.read!(path) =~ "defmodule GenKeep.Sitemaps do"
  end

  test "rejects invalid module names" do
    assert_raise Mix.Error, ~r/expected a module name/, fn -> Gen.run([]) end
    assert_raise Mix.Error, ~r/expected a module name, got: "my_app"/, fn -> Gen.run(["my_app"]) end
  end

  defp compile!(path) do
    {result, diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(path) end)
    assert diagnostics == []
    assert [{module, _}] = result
    module
  end
end
