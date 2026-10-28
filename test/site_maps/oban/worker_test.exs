defmodule SiteMaps.Oban.WorkerTest do
  use ExUnit.Case, async: true

  alias SiteMaps.Oban.Worker

  defmodule Sitemaps do
    use SiteMaps

    def config(_context), do: [url: "https://acme.com/sitemap.xml", adapter: {SiteMaps.Adapters.Noop, []}]

    process :static

    process :posts, "posts/%{year}-%{month}/sitemap.xml",
      args: [year: :integer, month: :integer],
      defaults: [year: 2025, month: 1]

    process :days, "days/%{day}/sitemap.xml", args: [day: :date], defaults: [day: &Date.utc_today/0]

    def urls(_name, _args, _context), do: []
  end

  defmodule RequiredSitemaps do
    use SiteMaps

    def config(_context), do: [url: "https://acme.com/sitemap.xml", adapter: {SiteMaps.Adapters.Noop, []}]

    process :posts, "posts/%{year}/sitemap.xml", args: [year: :integer]

    def urls(_name, _args, _context), do: []
  end

  defmodule LoadingSitemaps do
    use SiteMaps

    def config(_context), do: [url: "https://acme.com/sitemap.xml", adapter: {SiteMaps.Adapters.Noop, []}]
    def load_context(%{"site" => slug}), do: %{site: %{slug: slug}}

    process :static

    def urls(_name, _args, _context), do: []
  end

  defp build_job(module, opts) do
    %{changes: %{args: args}} = Worker.new_job(module, opts)
    Oban.Testing.build_job(Worker, args, [])
  end

  defp perform(job, result \\ {:ok, %SiteMaps.Result{}}) do
    Worker.perform(job, fn module, opts ->
      send(self(), {:generate, module, opts})
      result
    end)
  end

  describe "new_job/2" do
    test "builds the args on the sitemaps queue with uniqueness" do
      changeset = Worker.new_job(Sitemaps, context: %{site: "acme"}, prune: true, priority: 2)

      assert changeset.valid?
      assert changeset.changes.queue == "sitemaps"
      assert changeset.changes.priority == 2

      assert %{"run" => run} = args = changeset.changes.args
      assert run =~ ~r/^[0-9a-f]{64}$/

      assert Map.delete(args, "run") == %{
               "module" => "Elixir.SiteMaps.Oban.WorkerTest.Sitemaps",
               "context" => %{"site" => "acme"},
               "only" => [
                 %{"process" => "static", "args" => %{}},
                 %{"process" => "posts", "args" => %{"year" => 2025, "month" => 1}},
                 %{"process" => "days", "args" => %{"day" => Date.utc_today()}}
               ],
               "all" => true,
               "prune" => true
             }

      assert %{keys: [:run], period: :infinity} = changeset.changes.unique
    end

    test "identifies a run by module, context and resolved processes" do
      run = &Worker.new_job(Sitemaps, &1).changes.args["run"]
      acme = run.(context: %{site: "acme"}, only: [posts: [year: 2026]])

      assert acme == run.(context: %{"site" => "acme"}, only: [posts: [year: 2026, month: 1]], prune: true)
      refute acme == run.(context: %{site: "acme"})
      refute run.([]) == run.(only: [:static, :posts, :days])
      refute acme == run.(context: %{site: "acme", lang: "pt"}, only: [posts: [year: 2026]])
      refute acme == run.(context: %{}, only: [posts: [year: 2026]])
      refute acme == run.(context: %{site: "acme"}, only: [:static, posts: [year: 2026]])
      refute acme == Worker.new_job(LoadingSitemaps, context: %{site: "acme"}).changes.args["run"]
    end

    test "resolves process args and defaults at enqueue time" do
      %{changes: %{args: args}} = Worker.new_job(Sitemaps, only: [:static, posts: [year: 2026], days: []])

      assert args["only"] == [
               %{"process" => "static", "args" => %{}},
               %{"process" => "posts", "args" => %{"year" => 2026, "month" => 1}},
               %{"process" => "days", "args" => %{"day" => Date.utc_today()}}
             ]
    end

    test "resolves the defaults of every process when only is not given" do
      %{changes: %{args: args}} = Worker.new_job(Sitemaps, [])

      assert args["all"]
      assert Enum.map(args["only"], & &1["process"]) == ["static", "posts", "days"]
      assert %{"process" => "days", "args" => %{"day" => day}} = List.last(args["only"])
      assert day == Date.utc_today()
    end

    test "encodes a full run as every process with its defaults" do
      only = &Worker.new_job(Sitemaps, &1).changes.args["only"]

      assert only.([]) == only.(only: [:static, :posts, :days])
      refute only.([]) == only.(only: [:static, :posts, days: [day: Date.add(Date.utc_today(), -1)]])
    end

    test "raises for unknown processes and args" do
      assert_raise ArgumentError, ~r/unknown sitemap process :nope/, fn -> Worker.new_job(Sitemaps, only: [:nope]) end
      assert_raise ArgumentError, ~r/missing argument :year/, fn -> Worker.new_job(RequiredSitemaps, only: [:posts]) end
      assert_raise ArgumentError, ~r/missing argument :year/, fn -> Worker.new_job(RequiredSitemaps, []) end
    end
  end

  describe "perform/1" do
    test "runs generate with the decoded args" do
      job = build_job(Sitemaps, context: %{site: "acme"}, only: [:static, posts: [year: 2026, month: 3]], prune: true)

      assert :ok = perform(job)
      assert_received {:generate, Sitemaps, opts}
      assert opts[:context] == %{"site" => "acme"}
      assert opts[:only] == [:static, posts: [year: 2026, month: 3]]
      assert opts[:prune] == true
    end

    test "passes JSON encoded values for core to cast" do
      job = build_job(Sitemaps, only: [days: [day: ~D[2026-03-01]]])

      assert :ok = perform(job)
      assert_received {:generate, Sitemaps, opts}
      assert opts[:only] == [days: [day: "2026-03-01"]]
      assert SiteMaps.Process.build_args(day_process(), opts[:only][:days]) == %{day: ~D[2026-03-01]}
    end

    test "runs every process with the defaults resolved at enqueue time" do
      job = build_job(Sitemaps, [])
      job = %{job | args: update_in(job.args, ["only", Access.at(2), "args", "day"], fn _ -> "2026-03-01" end)}

      assert :ok = perform(job)
      assert_received {:generate, Sitemaps, opts}
      assert opts[:only] == [:static, posts: [year: 2025, month: 1], days: [day: "2026-03-01"]]
    end

    test "runs a full run without only when no process takes arguments" do
      assert :ok = LoadingSitemaps |> build_job(context: %{site: "acme"}) |> perform()
      assert_received {:generate, LoadingSitemaps, opts}
      assert opts[:only] == nil
    end

    test "keeps an explicit only when no process takes arguments" do
      assert :ok = LoadingSitemaps |> build_job(context: %{site: "acme"}, only: [:static]) |> perform()
      assert_received {:generate, LoadingSitemaps, opts}
      assert opts[:only] == [:static]
    end

    test "runs every process for jobs enqueued without only" do
      job = Oban.Testing.build_job(Worker, %{"module" => to_string(Sitemaps), "only" => nil}, [])

      assert :ok = perform(job)
      assert_received {:generate, Sitemaps, [context: %{}, only: nil, prune: false]}
    end

    test "loads the context with load_context/1" do
      assert :ok = LoadingSitemaps |> build_job(context: %{site: "acme"}) |> perform()
      assert_received {:generate, LoadingSitemaps, opts}
      assert opts[:context] == %{site: %{slug: "acme"}}
    end

    test "raises for processes no longer declared" do
      job = Oban.Testing.build_job(Worker, %{"module" => to_string(Sitemaps), "only" => [%{"process" => "gone"}]}, [])

      assert_raise ArgumentError, ~r/unknown sitemap process "gone"/, fn -> perform(job) end
    end

    test "returns generate errors" do
      assert {:error, :boom} = Sitemaps |> build_job([]) |> perform({:error, :boom})
    end
  end

  defp day_process, do: Enum.find(SiteMaps.processes(Sitemaps), &(&1.name == :days))
end
