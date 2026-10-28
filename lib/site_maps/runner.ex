defmodule SiteMaps.Runner do
  @moduledoc false

  alias SiteMaps.{Adapter, Config, Index, IndexEntry, Location, Process, Result, URL, Writer}

  @spec run(module, keyword) :: {:ok, Result.t()} | {:error, term}
  def run(module, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    meta = %{module: module, context: context, only: opts[:only]}

    :telemetry.span([:site_maps, :run], meta, fn ->
      result = do_run(module, context, opts)
      {result, Map.put(meta, :result, result)}
    end)
  end

  defp do_run(module, context, opts) do
    config = SiteMaps.config!(module, context)

    tmp_dir =
      Path.join(config.tmp_dir, "site_maps-run-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))

    config = %{
      config
      | max_concurrency: opts[:max_concurrency] || config.max_concurrency,
        tmp_dir: tmp_dir
    }

    executions = plan(module, opts[:only])
    check_locations!(module, config, executions)
    externals = externals(module, context)
    counters = :ets.new(__MODULE__, [:public, :set])
    run = %{module: module, context: context, config: config, counters: counters, inline?: inline?(module, externals)}

    try do
      File.mkdir_p!(tmp_dir)

      with {:ok, outcomes} <- run_all(run, executions) do
        finish(run, outcomes, externals, Keyword.get(opts, :prune, false))
      end
    after
      :ets.delete(counters)
      File.rm_rf(tmp_dir)
    end
  end

  @doc false
  @spec plan(module, list | nil) :: [{Process.t(), map}]
  def plan(module, only) do
    processes = SiteMaps.processes(module)
    by_name = Map.new(processes, &{&1.name, &1})

    executions =
      case only do
        nil -> Enum.map(processes, &{&1, Process.build_args(&1, [])})
        list -> Enum.map(list, &execution(module, by_name, &1))
      end

    case executions -- Enum.uniq(executions) do
      [] ->
        executions

      [{process, args} | _] ->
        raise ArgumentError, "sitemap process #{inspect(process.name)} enqueued twice with #{inspect(args)}"
    end
  end

  defp execution(module, by_name, {name, args}) do
    process = fetch_process!(module, by_name, name)
    {process, Process.build_args(process, args)}
  end

  defp execution(module, by_name, name), do: execution(module, by_name, {name, []})

  defp fetch_process!(module, by_name, name) do
    Enum.find_value(by_name, fn {key, process} -> if key == name or Atom.to_string(key) == name, do: process end) ||
      raise ArgumentError, "#{inspect(module)} has no sitemap process #{inspect(name)}"
  end

  defp externals(module, context) do
    if function_exported?(module, :external_sitemaps, 1) do
      Enum.map(module.external_sitemaps(context), fn
        {loc, lastmod} -> %IndexEntry{loc: loc, lastmod: lastmod}
        loc when is_binary(loc) -> %IndexEntry{loc: loc}
      end)
    else
      []
    end
  end

  defp inline?(module, []), do: match?([%Process{location: nil, args: []}], SiteMaps.processes(module))
  defp inline?(_module, _externals), do: false

  defp check_locations!(module, config, executions) do
    families = Enum.map(executions, fn {process, args} -> {Location.family(config, process, args), process, args} end)

    families
    |> Enum.group_by(fn {family, _, _} -> Location.counter_key(family) end)
    |> Enum.find(fn {_key, list} -> length(list) > 1 end)
    |> case do
      nil ->
        :ok

      {_key, [{_, p1, a1}, {_, p2, a2} | _]} ->
        raise ArgumentError,
              "sitemap executions #{inspect({p1.name, a1})} and #{inspect({p2.name, a2})} write to the same files"
    end

    for process <- SiteMaps.processes(module), Regex.match?(Location.pattern(config, process), config.index_key) do
      raise ArgumentError,
            "the index #{config.index_key} may collide with the files of sitemap process #{inspect(process.name)}"
    end

    :ok
  end

  defp run_all(run, executions) do
    SiteMaps.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(executions, &execute(run, &1),
      max_concurrency: run.config.max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, outcome}}, {:ok, acc} -> {:cont, {:ok, [outcome | acc]}}
      {:ok, {:error, _} = error}, _acc -> {:halt, error}
      {:exit, reason}, _acc -> {:halt, {:error, {:process_exit, reason}}}
    end)
  end

  defp execute(run, {process, args}) do
    meta = %{module: run.module, process: process.name, args: args}

    try do
      :telemetry.span([:site_maps, :process], meta, fn -> {{:ok, write_process(run, process, args)}, meta} end)
    catch
      kind, reason -> {:error, {:process_failed, process.name, args, kind, reason, __STACKTRACE__}}
    end
  end

  defp write_process(run, process, args) do
    family = Location.family(run.config, process, args)

    files =
      process.name
      |> run.module.urls(args, run.context)
      |> Stream.map(&prepare(run, process, &1))
      |> Stream.reject(&is_nil/1)
      |> Writer.write(run.config, fn file ->
        if run.inline?, do: {:pending, file}, else: publish(run, process, family, file)
      end)

    entries =
      case files do
        [{:pending, file}] -> [publish(run, process, run.config.index_key, file)]
        [{:pending, _} | _] -> Enum.map(files, fn {:pending, file} -> publish(run, process, family, file) end)
        published -> published
      end

    %{
      family: family,
      entries: entries,
      inline?: run.inline? and length(files) == 1,
      links: Enum.sum(Enum.map(entries, & &1.links)),
      news: Enum.sum(Enum.map(entries, & &1.news))
    }
  end

  defp prepare(run, process, %URL{} = url) do
    url = resolve(url, run)

    case filter(run, url) do
      nil -> nil
      %URL{} = filtered -> filtered |> resolve(run) |> check(run, process)
    end
  end

  defp prepare(_run, _process, other) do
    raise ArgumentError, "sitemap processes must emit SiteMaps.URL structs, got: #{inspect(other)}"
  end

  defp resolve(%URL{} = url, %{config: config}) do
    url
    |> Map.update!(:loc, &Config.resolve_loc(config, &1))
    |> URL.map_locs(&Config.resolve_loc(config, &1))
  end

  defp filter(run, url) do
    if function_exported?(run.module, :url_filter, 2), do: run.module.url_filter(url, run.context), else: url
  end

  defp check(%URL{loc: loc} = url, run, process) do
    if URL.loc_length(loc) >= URL.max_loc_length() do
      raise ArgumentError, "sitemap URLs must be shorter than #{URL.max_loc_length()} characters: #{loc}"
    end

    if URI.parse(loc).host != run.config.root_uri.host do
      :telemetry.execute([:site_maps, :url, :foreign_host], %{count: 1}, %{
        module: run.module,
        process: process.name,
        loc: loc
      })
    end

    url
  end

  defp publish(run, process, %Location{} = family, file) do
    n = :ets.update_counter(run.counters, Location.counter_key(family), 1, {Location.counter_key(family), 0})
    publish(run, process, Location.key(family, n), file)
  end

  defp publish(run, process, key, file) when is_binary(key) do
    config = run.config

    meta = %{
      content_type: if(config.gzip?, do: "application/gzip", else: "application/xml"),
      cache_control: config.cache_control,
      last_modified: Writer.to_datetime(file.lastmod)
    }

    try do
      case Adapter.write(config.adapter, key, {:file, file.path}, meta) do
        :ok -> :ok
        {:error, reason} -> raise SiteMaps.Error, reason: {:write_failed, key, reason}
      end
    after
      File.rm(file.path)
    end

    url = Config.key_to_url(config, key)

    :telemetry.execute(
      [:site_maps, :urlset, :write],
      %{links: file.links, news: file.news, bytes: file.bytes},
      %{module: run.module, process: process.name, key: key, url: url}
    )

    %{entry: %IndexEntry{loc: url, lastmod: file.lastmod}, links: file.links, news: file.news}
  end

  defp finish(run, outcomes, externals, prune?) do
    files = Enum.flat_map(outcomes, fn outcome -> Enum.map(outcome.entries, & &1.entry) end)
    totals = %{links: Enum.sum(Enum.map(outcomes, & &1.links)), news: Enum.sum(Enum.map(outcomes, & &1.news))}

    result =
      if Enum.any?(outcomes, & &1.inline?) do
        with {:ok, pruned} <- Index.prune(run.config, Enum.map(outcomes, & &1.family), [], prune?) do
          {:ok, %{index: run.config.url, pruned: pruned}}
        end
      else
        with {:ok, published} <- Index.publish(run, Enum.map(outcomes, & &1.family), files, externals, prune?) do
          {:ok, %{index: if(published.written?, do: run.config.url), pruned: published.pruned}}
        end
      end

    with {:ok, extra} <- result do
      {:ok, struct(Result, totals |> Map.merge(extra) |> Map.put(:files, files))}
    end
  end
end
