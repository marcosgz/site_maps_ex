defmodule Mix.Tasks.SiteMaps.Generate do
  @shortdoc "Generates the sitemaps of a SiteMaps module"

  @moduledoc """
  Generates the sitemaps of a module that uses `SiteMaps`.

      $ mix site_maps.generate MyApp.Sitemaps
      $ mix site_maps.generate MyApp.Sitemaps posts,news --context site=acme --arg year=2026 --arg month=3

  The optional second argument is a comma-separated list of processes to run. Without it every
  process runs with its default arguments.

  ## Options

    * `--context key=value` - context entry, repeatable. When the module implements
      `c:SiteMaps.load_context/1` it receives the string-keyed map; otherwise the callbacks get a map
      with atom keys and string values.
    * `--arg key=value` - process argument, repeatable, given to each listed process that declares it
      and cast to the declared argument type. An argument no listed process declares is an error.
    * `--max-concurrency N` - number of processes run in parallel
    * `--prune` - delete files of the regenerated processes that are no longer listed
    * `--quiet` - do not log progress
  """

  use Mix.Task

  @switches [context: :keep, arg: :keep, max_concurrency: :integer, prune: :boolean, quiet: :boolean]

  @impl Mix.Task
  def run(argv), do: run(argv, &SiteMaps.generate/2)

  @doc false
  def run(argv, generate) do
    {module, opts} = parse_args(argv)
    {quiet?, opts} = Keyword.pop(opts, :quiet, false)

    Mix.Task.run("app.start")
    ensure_sitemaps!(module)
    unless quiet?, do: SiteMaps.Telemetry.attach_default_logger()

    opts =
      opts
      |> Keyword.update!(:context, &load_context(module, &1))
      |> Keyword.update!(:only, &scope_args!(module, &1))

    case generate.(module, opts) do
      {:ok, result} -> unless quiet?, do: Mix.shell().info(summary(module, result))
      {:error, reason} -> Mix.raise(Exception.message(%SiteMaps.Error{reason: reason}))
    end
  end

  @doc """
  Parses the command line into the module and the `SiteMaps.generate/2` options. The context is
  kept as a string-keyed map and the `:quiet` flag is included.
  """
  @spec parse_args([String.t()]) :: {module, keyword}
  def parse_args(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [name | rest], []} -> {module!(name), build_opts(opts, processes!(rest))}
      {_opts, [], []} -> Mix.raise("expected a sitemap module, e.g. mix site_maps.generate MyApp.Sitemaps")
      {_opts, _args, invalid} -> Mix.raise("invalid options: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end
  end

  defp build_opts(opts, processes) do
    args = opts |> Keyword.get_values(:arg) |> Enum.map(&pair!(&1, "--arg"))

    [
      context: opts |> Keyword.get_values(:context) |> Map.new(&pair!(&1, "--context")),
      only: only!(processes, args),
      prune: Keyword.get(opts, :prune, false),
      quiet: Keyword.get(opts, :quiet, false)
    ]
    |> put_present(:max_concurrency, opts[:max_concurrency])
  end

  defp only!(nil, []), do: nil

  defp only!(nil, _args),
    do: Mix.raise("--arg requires the processes to run, e.g. mix site_maps.generate MyApp.Sitemaps posts")

  defp only!(names, []), do: names

  defp only!(names, args) do
    keyword = Enum.map(args, fn {key, value} -> {String.to_atom(key), value} end)
    Enum.map(names, &{&1, keyword})
  end

  defp scope_args!(_module, nil), do: nil

  defp scope_args!(module, only) do
    declared = Map.new(SiteMaps.processes(module), &{&1.name, Keyword.keys(&1.args)})

    scoped =
      Enum.map(only, fn
        {name, args} -> scope(name, args, Map.get(declared, name))
        name -> name
      end)

    case arg_keys(only) -- arg_keys(scoped) do
      [] -> scoped
      unused -> Mix.raise("no listed process declares the argument(s): #{Enum.join(unused, ", ")}")
    end
  end

  defp scope(name, args, nil), do: {name, args}

  defp scope(name, args, declared) do
    case Keyword.take(args, declared) do
      [] -> name
      taken -> {name, taken}
    end
  end

  defp arg_keys(only),
    do: only |> Enum.flat_map(&if(is_tuple(&1), do: Keyword.keys(elem(&1, 1)), else: [])) |> Enum.uniq()

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp module!(name) do
    if name =~ ~r/^[A-Z]\w*(\.[A-Z]\w*)*$/,
      do: Module.concat([name]),
      else: Mix.raise("expected a module name, got: #{inspect(name)}")
  end

  defp processes!([]), do: nil

  defp processes!([list]) do
    case list |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> Mix.raise("expected a comma-separated list of processes, got: #{inspect(list)}")
      names -> Enum.map(names, &String.to_atom/1)
    end
  end

  defp processes!([_list | extra]), do: Mix.raise("unexpected arguments: #{Enum.join(extra, " ")}")

  defp pair!(entry, option) do
    case String.split(entry, "=", parts: 2) do
      [key, value] when key != "" -> {key, value}
      _ -> Mix.raise("expected #{option} key=value, got: #{inspect(entry)}")
    end
  end

  defp ensure_sitemaps!(module) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :__site_maps__, 1) do
      Mix.raise("#{inspect(module)} is not a module that uses SiteMaps")
    end
  end

  defp load_context(module, context) do
    if function_exported?(module, :load_context, 1),
      do: module.load_context(context),
      else: Map.new(context, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp summary(module, %SiteMaps.Result{} = result) do
    "#{inspect(module)}: #{result.links} links in #{length(result.files)} files" <>
      if(result.index, do: ", index #{result.index}", else: "")
  end
end
