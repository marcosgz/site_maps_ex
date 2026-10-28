defmodule Mix.Tasks.SiteMaps.GenerateTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SiteMaps.Generate

  defmodule Sitemaps do
    use SiteMaps

    def config(_context), do: [url: "https://acme.com/sitemap.xml", adapter: {SiteMaps.Adapters.Noop, []}]

    process :static
    process :posts, "posts/%{year}-%{month}/sitemap.xml", args: [year: :integer, month: :integer]

    def urls(_name, _args, _context), do: []
  end

  defmodule LoadingSitemaps do
    use SiteMaps

    def config(_context), do: [url: "https://acme.com/sitemap.xml", adapter: {SiteMaps.Adapters.Noop, []}]
    def load_context(%{"site" => slug}), do: %{site: %{slug: slug}}

    process :static

    def urls(_name, _args, _context), do: []
  end

  @module inspect(Sitemaps)

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  describe "parse_args/1" do
    test "runs every process by default" do
      assert Generate.parse_args([@module]) ==
               {Sitemaps, [context: %{}, only: nil, prune: false, quiet: false]}
    end

    test "parses processes, context, args and flags" do
      argv =
        ~w(#{@module} static,posts --context site=acme --context lang=pt-BR --arg year=2026 --arg month=3) ++
          ~w(--max-concurrency 4 --prune --quiet)

      assert {Sitemaps, opts} = Generate.parse_args(argv)
      assert opts[:context] == %{"site" => "acme", "lang" => "pt-BR"}
      assert opts[:only] == [static: [year: "2026", month: "3"], posts: [year: "2026", month: "3"]]
      assert opts[:max_concurrency] == 4
      assert opts[:prune]
      assert opts[:quiet]
    end

    test "lists processes without args as names" do
      assert {_, opts} = Generate.parse_args([@module, " static , news,"])
      assert opts[:only] == [:static, :news]
    end

    test "keeps everything after the first = in values" do
      assert {_, opts} = Generate.parse_args([@module, "--context", "query=a=b"])
      assert opts[:context] == %{"query" => "a=b"}
    end

    test "rejects invalid input" do
      assert_raise Mix.Error, ~r/expected a sitemap module/, fn -> Generate.parse_args([]) end
      assert_raise Mix.Error, ~r/expected a module name/, fn -> Generate.parse_args(["my_app"]) end
      assert_raise Mix.Error, ~r/invalid options: --nope/, fn -> Generate.parse_args([@module, "--nope"]) end
      assert_raise Mix.Error, ~r/--context key=value/, fn -> Generate.parse_args([@module, "--context", "site"]) end
      assert_raise Mix.Error, ~r/--arg key=value/, fn -> Generate.parse_args([@module, "posts", "--arg", "=1"]) end
      assert_raise Mix.Error, ~r/--arg requires/, fn -> Generate.parse_args([@module, "--arg", "year=1"]) end
      assert_raise Mix.Error, ~r/list of processes/, fn -> Generate.parse_args([@module, ","]) end

      assert_raise Mix.Error, ~r/unexpected arguments: a b/, fn ->
        Generate.parse_args([@module, "static", "a", "b"])
      end
    end
  end

  describe "run/2" do
    test "calls generate with atom keyed context" do
      result = %SiteMaps.Result{index: "https://acme.com/sitemap.xml", files: [], links: 3}

      Generate.run(~w(#{@module} posts --context site=acme --arg year=2026 --quiet), fn module, opts ->
        send(self(), {:generate, module, opts})
        {:ok, result}
      end)

      assert_received {:generate, Sitemaps, opts}
      assert opts == [context: %{site: "acme"}, only: [posts: [year: "2026"]], prune: false]
      refute_received {:mix_shell, :info, _}
    end

    test "gives each listed process only the args it declares" do
      Generate.run(~w(#{@module} static,posts --arg year=2026 --arg month=3 --max-concurrency 2 --quiet), fn _module,
                                                                                                             opts ->
        send(self(), {:generate, opts})
        {:ok, %SiteMaps.Result{}}
      end)

      assert_received {:generate, opts}
      assert opts[:only] == [:static, posts: [year: "2026", month: "3"]]
      assert opts[:max_concurrency] == 2

      [static, posts] = SiteMaps.processes(Sitemaps)
      assert SiteMaps.Process.build_args(static, []) == %{}
      assert SiteMaps.Process.build_args(posts, opts[:only][:posts]) == %{year: 2026, month: 3}
    end

    test "raises for args no listed process declares" do
      assert_raise Mix.Error, ~r/no listed process declares the argument\(s\): day/, fn ->
        Generate.run(~w(#{@module} static,posts --arg year=2026 --arg day=1 --quiet), fn _, _ ->
          flunk("must not run")
        end)
      end
    end

    test "passes the string keyed context to load_context/1" do
      Generate.run(~w(#{inspect(LoadingSitemaps)} --context site=acme --quiet), fn _module, opts ->
        send(self(), {:context, opts[:context]})
        {:ok, %SiteMaps.Result{}}
      end)

      assert_received {:context, %{site: %{slug: "acme"}}}
    end

    test "attaches the logger and prints a summary unless quiet" do
      on_exit(&SiteMaps.Telemetry.detach_default_logger/0)
      result = %SiteMaps.Result{index: "https://acme.com/sitemap.xml", links: 3}

      Generate.run([@module], fn _module, _opts -> {:ok, result} end)

      assert_received {:mix_shell, :info, [summary]}
      assert summary =~ "3 links"
      assert summary =~ "https://acme.com/sitemap.xml"
      assert Enum.any?(:telemetry.list_handlers([:site_maps]), &(&1.id == "site-maps-default-logger"))
    end

    test "raises on errors" do
      assert_raise Mix.Error, ~r/sitemap generation failed: :boom/, fn ->
        Generate.run([@module, "--quiet"], fn _module, _opts -> {:error, :boom} end)
      end
    end

    test "raises when the module does not use SiteMaps" do
      assert_raise Mix.Error, ~r/Enum is not a module that uses SiteMaps/, fn ->
        Generate.run(["Enum", "--quiet"], fn _module, _opts -> flunk("generate must not run") end)
      end
    end
  end
end
