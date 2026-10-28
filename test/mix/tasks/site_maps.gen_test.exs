defmodule Mix.Tasks.SiteMaps.GenTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SiteMaps.Gen

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "writes a sitemap module that compiles cleanly", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn -> Gen.run(["GenTestApp.Sitemaps"]) end)

    path = Path.join(tmp_dir, "lib/gen_test_app/sitemaps.ex")
    assert File.exists?(path)
    assert_received {:mix_shell, :info, [_created]}
    assert_received {:mix_shell, :info, [next_steps]}
    assert next_steps =~ "mix site_maps.generate GenTestApp.Sitemaps"

    {result, diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(path) end)
    assert [{module, _}] = result
    assert module == GenTestApp.Sitemaps
    assert diagnostics == []

    assert Enum.map(SiteMaps.processes(module), & &1.name) == [:static, :archive]
    assert [url: _, adapter: {SiteMaps.Adapters.FileSystem, _}] = module.config(%{})
    assert module.current_month() == Calendar.strftime(Date.utc_today(), "%Y-%m")

    today = Date.utc_today()
    archive = Enum.to_list(module.urls(:archive, %{month: module.current_month()}, %{}))
    assert length(archive) == today.day
    assert Enum.all?(archive, &(Date.compare(&1.lastmod, today) != :gt))
    assert module.urls(:archive, %{month: "#{today.year + 1}-01"}, %{}) |> Enum.to_list() == []
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
end
