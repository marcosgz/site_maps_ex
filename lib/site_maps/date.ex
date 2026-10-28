defmodule SiteMaps.Date do
  @moduledoc """
  W3C datetime normalization and formatting for sitemap dates.

  A `NaiveDateTime` is treated as UTC, a `DateTime` or ISO 8601 string keeps its offset and a
  `Date` is written as `YYYY-MM-DD`. Sub-second precision is dropped.
  """

  @type t :: DateTime.t() | Date.t()

  @doc """
  Formats a date in the W3C datetime format.

      iex> SiteMaps.Date.w3c(~U[2026-03-01 10:00:00.123Z])
      "2026-03-01T10:00:00+00:00"

      iex> SiteMaps.Date.w3c(~N[2026-03-01 10:00:00])
      "2026-03-01T10:00:00+00:00"

      iex> SiteMaps.Date.w3c(~D[2026-03-01])
      "2026-03-01"
  """
  @spec w3c(DateTime.t() | NaiveDateTime.t() | Date.t()) :: String.t()
  def w3c(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> utc_offset()
  end

  def w3c(%NaiveDateTime{} = naive), do: naive |> to_utc() |> w3c()
  def w3c(%Date{} = date), do: Date.to_iso8601(date)

  @doc """
  Casts a value to a `DateTime` or `Date`.

  Accepts `DateTime`, `NaiveDateTime` (as UTC), `Date` and ISO 8601 strings. `nil` stays `nil`.
  Raises `ArgumentError` for anything else, including integers.
  """
  @spec cast!(term, atom) :: t | nil
  def cast!(value, field \\ :date)
  def cast!(nil, _field), do: nil
  def cast!(%DateTime{} = datetime, _field), do: datetime
  def cast!(%NaiveDateTime{} = naive, _field), do: to_utc(naive)
  def cast!(%Date{} = date, _field), do: date

  def cast!(value, field) when is_binary(value) do
    case parse(value) do
      {:ok, date} -> date
      :error -> invalid!(value, field)
    end
  end

  def cast!(value, field), do: invalid!(value, field)

  defp parse(value) do
    with {:error, _} <- datetime(value),
         {:error, _} <- naive(value),
         {:error, _} <- Date.from_iso8601(value) do
      :error
    end
  end

  defp datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      {:ok, datetime, offset} -> {:ok, with_offset(datetime, offset)}
      error -> error
    end
  end

  defp with_offset(utc, offset) do
    local = utc |> DateTime.to_naive() |> NaiveDateTime.add(offset, :second)
    {:ok, datetime} = DateTime.from_naive(local, "Etc/UTC")
    zone = offset_string(offset)

    %{datetime | utc_offset: offset, std_offset: 0, time_zone: zone, zone_abbr: zone}
  end

  defp offset_string(offset) do
    sign = if offset < 0, do: "-", else: "+"
    minutes = div(abs(offset), 60)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    "#{sign}#{pad.(div(minutes, 60))}:#{pad.(rem(minutes, 60))}"
  end

  defp naive(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, to_utc(naive)}
      error -> error
    end
  end

  defp to_utc(naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp utc_offset(iso) do
    if String.ends_with?(iso, "Z"), do: String.replace_suffix(iso, "Z", "+00:00"), else: iso
  end

  defp invalid!(value, field) do
    raise ArgumentError,
          "expected #{field} to be a DateTime, NaiveDateTime, Date or ISO 8601 string, got: #{inspect(value)}"
  end
end
