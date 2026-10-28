defmodule SiteMaps.DateTest do
  use ExUnit.Case, async: true

  doctest SiteMaps.Date

  describe "w3c/1" do
    test "formats dates and datetimes" do
      for {value, expected} <- [
            {~D[2026-03-01], "2026-03-01"},
            {~U[2026-03-01 10:00:00Z], "2026-03-01T10:00:00+00:00"},
            {~U[2026-03-01 10:00:00.999999Z], "2026-03-01T10:00:00+00:00"},
            {~N[2026-03-01 10:00:00], "2026-03-01T10:00:00+00:00"},
            {~N[2026-12-31 23:59:59.5], "2026-12-31T23:59:59+00:00"}
          ] do
        assert SiteMaps.Date.w3c(value) == expected
      end
    end

    test "keeps the offset of a non-UTC datetime" do
      datetime = %DateTime{
        year: 2026,
        month: 3,
        day: 1,
        hour: 7,
        minute: 0,
        second: 0,
        microsecond: {0, 0},
        time_zone: "America/Sao_Paulo",
        zone_abbr: "-03",
        utc_offset: -10_800,
        std_offset: 0
      }

      assert SiteMaps.Date.w3c(datetime) == "2026-03-01T07:00:00-03:00"
    end
  end

  describe "cast!/2" do
    test "keeps dates and datetimes" do
      assert SiteMaps.Date.cast!(~D[2026-03-01]) == ~D[2026-03-01]
      assert SiteMaps.Date.cast!(~U[2026-03-01 10:00:00Z]) == ~U[2026-03-01 10:00:00Z]
      assert SiteMaps.Date.cast!(nil) == nil
    end

    test "treats NaiveDateTime as UTC" do
      assert SiteMaps.Date.cast!(~N[2026-03-01 10:00:00]) == ~U[2026-03-01 10:00:00Z]
    end

    test "parses ISO 8601 strings" do
      assert SiteMaps.Date.cast!("2026-03-01") == ~D[2026-03-01]
      assert SiteMaps.Date.cast!("2026-03-01T10:00:00Z") == ~U[2026-03-01 10:00:00Z]
      assert SiteMaps.Date.cast!("2026-03-01T10:00:00") == ~U[2026-03-01 10:00:00Z]
    end

    test "keeps the offset of an ISO 8601 string" do
      datetime = SiteMaps.Date.cast!("2026-03-01T07:00:00-03:00")

      assert DateTime.compare(datetime, ~U[2026-03-01 10:00:00Z]) == :eq
      assert SiteMaps.Date.w3c(datetime) == "2026-03-01T07:00:00-03:00"
      assert SiteMaps.Date.w3c(SiteMaps.Date.cast!("2026-03-01T10:00:00+05:30")) == "2026-03-01T10:00:00+05:30"
      assert SiteMaps.Date.w3c(SiteMaps.Date.cast!("2026-03-01T10:00:00+00:00")) == "2026-03-01T10:00:00+00:00"
    end

    test "raises on integers, unknown types and invalid strings" do
      for value <- [0, 1_700_000_000, 1.5, :now, "yesterday", "2026-13-01", {2026, 3, 1}] do
        assert_raise ArgumentError, ~r/lastmod/, fn -> SiteMaps.Date.cast!(value, :lastmod) end
      end
    end
  end
end
