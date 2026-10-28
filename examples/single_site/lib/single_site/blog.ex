defmodule SingleSite.Blog do
  @moduledoc "Deterministic fake posts standing in for a database."

  @doc "Posts published in a month, none in the future."
  def posts(year, month) do
    first = Date.new!(year, month, 1)

    if Date.compare(first, Date.utc_today()) == :gt do
      []
    else
      count = rem(:erlang.phash2({year, month}), 15) + 3

      for n <- 1..count do
        day = min(n, Date.days_in_month(first))

        %{
          slug: "#{year}-#{month}-story-#{n}",
          title: "Story #{n} of #{year}-#{month}",
          updated_at: DateTime.new!(Date.new!(year, month, day), ~T[12:00:00], "Etc/UTC")
        }
      end
    end
  end
end
