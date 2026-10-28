if Code.ensure_loaded?(Oban.Worker) do
  defmodule SiteMaps.Oban.Worker do
    @moduledoc """
    Oban worker that runs `SiteMaps.generate/2`. Compiled only when Oban is available.

        MyApp.Sitemaps
        |> SiteMaps.Oban.Worker.new_job(context: %{site: "acme"}, only: [posts: [year: 2026, month: 3]])
        |> Oban.insert()

    Jobs run on the `:sitemaps` queue. Process arguments, including declared defaults, are resolved
    when the job is built, so a retried job regenerates the same shards. Inserting a job is a no-op
    while an identical run (same module, context and resolved processes) is available, scheduled,
    executing or retryable; once that job completes, is discarded or cancelled, the same run can be
    enqueued again. Different runs of the same context, e.g. a full run and a partial one, are
    separate jobs and may run at the same time; to serialize the runs of a site, give each site its
    own queue with `limit: 1` (pass `queue:` to `new_job/2`) or run the `:sitemaps` queue with
    `limit: 1`.

    The context must be JSON serializable and arrives at the callbacks as the decoded, string-keyed
    map. A sitemap module that implements `c:SiteMaps.load_context/1` receives that map to build its
    own context (e.g. to load a `%Site{}` from its slug).
    """

    use Oban.Worker,
      queue: :sitemaps,
      unique: [
        period: :infinity,
        states: [:available, :scheduled, :executing, :retryable],
        keys: [:run]
      ]

    @doc """
    Builds the job changeset for `module`.

    ## Options

      * `:context` - JSON serializable map (default `%{}`)
      * `:only` - processes to run, e.g. `[:static, posts: [year: 2026, month: 3]]`. By default
        every declared process runs. Missing arguments are filled with the declared defaults now,
        so a retried job regenerates the same shards.
      * `:prune` - see `SiteMaps.generate/2` (default `false`)

    Other options (such as `queue:` or `scheduled_at:`) are given to the worker's `new/2`.
    """
    @spec new_job(module, keyword) :: Ecto.Changeset.t()
    def new_job(module, opts \\ []) do
      {context, opts} = Keyword.pop(opts, :context, %{})
      {only, opts} = Keyword.pop(opts, :only)
      {prune, opts} = Keyword.pop(opts, :prune, false)

      args = %{
        "module" => Atom.to_string(module),
        "context" => Map.new(context, fn {key, value} -> {to_string(key), value} end),
        "only" => encode_only(module, only || Enum.map(SiteMaps.processes(module), & &1.name)),
        "all" => is_nil(only),
        "prune" => prune
      }

      args
      |> Map.put("run", run_key(args))
      |> new(opts)
    end

    defp run_key(args) do
      run = Map.take(args, ["module", "context", "only", "all"])
      :sha256 |> :crypto.hash(:erlang.term_to_binary(run, [:deterministic])) |> Base.encode16(case: :lower)
    end

    @impl Oban.Worker
    def perform(job), do: perform(job, &SiteMaps.generate/2)

    @doc false
    def perform(%Oban.Job{args: args}, generate) do
      module = args |> Map.fetch!("module") |> String.to_existing_atom()
      Code.ensure_loaded!(module)

      opts = [
        context: load_context(module, Map.get(args, "context") || %{}),
        only: decode_only(module, Map.get(args, "only"), Map.get(args, "all", false)),
        prune: Map.get(args, "prune", false)
      ]

      case generate.(module, opts) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp encode_only(module, only) do
      Enum.map(only, fn entry ->
        {name, args} = if is_atom(entry), do: {entry, []}, else: entry
        process = process!(module, name)
        %{"process" => Atom.to_string(name), "args" => process |> SiteMaps.Process.build_args(args) |> stringify()}
      end)
    end

    defp stringify(args), do: Map.new(args, fn {key, value} -> {Atom.to_string(key), value} end)

    defp decode_only(_module, nil, _all?), do: nil

    defp decode_only(module, only, all?) do
      only = Enum.map(only, &decode_entry(module, &1))
      if all? and Enum.all?(only, &is_atom/1), do: nil, else: only
    end

    defp decode_entry(module, %{"process" => name} = entry) do
      process = process!(module, name)
      given = Map.get(entry, "args", %{})

      args =
        for {arg, _type} <- process.args,
            Map.has_key?(given, Atom.to_string(arg)),
            do: {arg, Map.fetch!(given, Atom.to_string(arg))}

      if args == [], do: process.name, else: {process.name, args}
    end

    defp process!(module, name) do
      Enum.find(SiteMaps.processes(module), &(&1.name == name or Atom.to_string(&1.name) == name)) ||
        raise ArgumentError, "unknown sitemap process #{inspect(name)} in #{inspect(module)}"
    end

    defp load_context(module, context) do
      if function_exported?(module, :load_context, 1), do: module.load_context(context), else: context
    end
  end
end
