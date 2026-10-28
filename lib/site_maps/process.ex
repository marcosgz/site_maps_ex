defmodule SiteMaps.Process do
  @moduledoc "A sitemap process declared with `SiteMaps.process/3`."

  @enforce_keys [:name]
  defstruct [:name, :location, args: [], defaults: []]

  @type arg_type :: :integer | :string | :date | :boolean | :atom
  @type t :: %__MODULE__{
          name: atom,
          location: String.t() | nil,
          args: [{atom, arg_type}],
          defaults: keyword
        }

  @doc "A process is dynamic when it declares arguments, so it can run many times with different ones."
  @spec dynamic?(t) :: boolean
  def dynamic?(%__MODULE__{args: args}), do: args != []

  @doc """
  Builds the argument map of an execution: declared defaults (values or 0-arity functions) are
  evaluated, given values are cast to the declared types, and unknown names raise.
  """
  @spec build_args(t, keyword | map) :: map
  def build_args(%__MODULE__{name: name, args: types, defaults: defaults}, given) do
    given = Map.new(given, fn {k, v} -> {to_atom!(name, types, k), v} end)

    Map.new(types, fn {arg, type} ->
      value =
        case Map.fetch(given, arg) do
          {:ok, value} -> value
          :error -> default!(name, arg, defaults)
        end

      {arg, cast!(name, arg, type, value)}
    end)
  end

  defp to_atom!(name, types, key) do
    found = Enum.find(types, fn {arg, _} -> arg == key or Atom.to_string(arg) == key end)
    found || raise ArgumentError, "unknown argument #{inspect(key)} for sitemap process #{inspect(name)}"
    elem(found, 0)
  end

  defp default!(name, arg, defaults) do
    case Keyword.fetch(defaults, arg) do
      {:ok, fun} when is_function(fun, 0) -> fun.()
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing argument #{inspect(arg)} for sitemap process #{inspect(name)}"
    end
  end

  defp cast!(_name, _arg, :integer, value) when is_integer(value), do: value
  defp cast!(_name, _arg, :string, value) when is_binary(value), do: value
  defp cast!(_name, _arg, :boolean, value) when is_boolean(value), do: value
  defp cast!(_name, _arg, :atom, value) when is_atom(value), do: value
  defp cast!(_name, _arg, :date, %Date{} = value), do: value

  defp cast!(name, arg, type, value) when is_binary(value) do
    case parse(type, value) do
      {:ok, cast} -> cast
      :error -> invalid!(name, arg, type, value)
    end
  end

  defp cast!(name, arg, type, value), do: invalid!(name, arg, type, value)

  defp parse(:integer, value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse(:boolean, value) when value in ~w(true false), do: {:ok, value == "true"}

  defp parse(:atom, value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  defp parse(:date, value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse(_type, _value), do: :error

  defp invalid!(name, arg, type, value) do
    raise ArgumentError,
          "invalid #{type} #{inspect(value)} for argument #{inspect(arg)} of sitemap process #{inspect(name)}"
  end
end
