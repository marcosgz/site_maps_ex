defmodule SiteMaps.Location do
  @moduledoc """
  Storage keys of the files written by a process execution.

  An execution writes a numbered family of files: the location `posts/%{year}/sitemap.xml` run
  with `year: 2026` writes `posts/2026/sitemap1.xml`, `posts/2026/sitemap2.xml`, ... (with `.gz`
  when the index is gzipped). A process without location writes `sitemap_<name>1.xml`, ... next
  to the index. When the file name ends with a digit, a `-` separates it from the counter
  (`posts-12-1.xml`). Keys are relative to the index directory and their path segments may only
  contain `A-Z a-z 0-9 . _ ~ -`, so they are valid URL paths as they are.
  """

  alias SiteMaps.{Config, Process}

  @enforce_keys [:dir, :stem, :ext]
  defstruct [:dir, :stem, :ext]

  @type t :: %__MODULE__{dir: String.t(), stem: String.t(), ext: String.t()}

  @segment "[A-Za-z0-9._~-]+"

  @doc "File family of `process` executed with `args`."
  @spec family(Config.t(), Process.t(), map) :: t
  def family(%Config{} = config, %Process{name: name} = process, args) do
    path =
      process
      |> template()
      |> interpolate(args, name)
      |> validate!(name)

    {dir, stem} = split(path)
    %__MODULE__{dir: dir, stem: stem, ext: ext(config)}
  end

  @doc "Key of the `n`-th file of the family."
  @spec key(t, pos_integer) :: String.t()
  def key(%__MODULE__{dir: dir, stem: stem, ext: ext}, n),
    do: dir <> stem <> separator(stem) <> Integer.to_string(n) <> ext

  @doc "Whether `key` belongs to the family."
  @spec member?(t, String.t()) :: boolean
  def member?(%__MODULE__{dir: dir, stem: stem, ext: ext}, key) do
    Regex.match?(~r/\A#{Regex.escape(dir <> stem <> separator(stem))}\d+#{Regex.escape(ext)}\z/, key)
  end

  @doc "Counter key shared by executions writing to the same family."
  @spec counter_key(t) :: {String.t(), String.t(), String.t()}
  def counter_key(%__MODULE__{dir: dir, stem: stem, ext: ext}), do: {dir, stem, ext}

  @doc "Regex matching the keys any execution of `process` may write."
  @spec pattern(Config.t(), Process.t()) :: Regex.t()
  def pattern(%Config{} = config, %Process{} = process) do
    {dir, stem} = process |> template() |> split()
    literal = fn text -> text |> String.split(~r/%\{\w+\}/, include_captures: true) |> Enum.map_join(&piece/1) end

    Regex.compile!("\\A" <> literal.(dir <> stem) <> "-?\\d+" <> Regex.escape(ext(config)) <> "\\z")
  end

  @doc false
  @spec template(Process.t()) :: String.t()
  def template(%Process{location: nil, name: name}), do: "sitemap_#{name}.xml"

  def template(%Process{location: location}) do
    location
    |> String.trim_leading("/")
    |> with_file_name()
    |> String.replace_suffix(".gz", "")
  end

  defp piece("%{" <> _), do: @segment
  defp piece(text), do: Regex.escape(text)

  defp split(path) do
    dir = Path.dirname(path)
    stem = path |> Path.basename() |> String.replace_suffix(".gz", "") |> String.replace_suffix(".xml", "")
    {if(dir == ".", do: "", else: dir <> "/"), stem}
  end

  defp separator(stem), do: if(stem =~ ~r/\d\z/, do: "-", else: "")

  defp ext(%Config{gzip?: true}), do: ".xml.gz"
  defp ext(%Config{gzip?: false}), do: ".xml"

  defp interpolate(template, args, name) do
    Regex.replace(~r/%\{(\w+)\}/, template, fn _, arg -> arg_value!(args, arg, name) end)
  end

  defp arg_value!(args, arg, name) do
    case Enum.find(args, fn {key, _} -> Atom.to_string(key) == arg end) do
      {_, value} -> segment!(to_string(value), arg, name)
      nil -> raise ArgumentError, "location of sitemap process #{inspect(name)} uses unknown argument %{#{arg}}"
    end
  end

  defp segment!(value, arg, name) do
    if value =~ ~r/\A#{@segment}\z/ and value not in [".", ".."] do
      value
    else
      raise ArgumentError,
            "argument %{#{arg}} of sitemap process #{inspect(name)} must be a path segment whose characters " <>
              "only contain A-Z a-z 0-9 . _ ~ -, got: #{inspect(value)}"
    end
  end

  defp with_file_name(path) do
    cond do
      String.ends_with?(path, [".xml", ".xml.gz"]) -> path
      path in ["", "/"] -> "sitemap.xml"
      true -> String.trim_trailing(path, "/") <> "/sitemap.xml"
    end
  end

  defp validate!(path, name) do
    segments = String.split(path, "/")

    unless Enum.all?(segments, &(&1 =~ ~r/\A#{@segment}\z/ and &1 not in [".", ".."])) do
      raise ArgumentError,
            "location #{inspect(path)} of sitemap process #{inspect(name)} must be a relative path inside the index " <>
              "directory whose segments only contain A-Z a-z 0-9 . _ ~ -"
    end

    path
  end
end
