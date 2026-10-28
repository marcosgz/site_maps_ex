defmodule SiteMaps.IndexEntry do
  @moduledoc "A `<sitemap>` entry of a sitemap index."

  @enforce_keys [:loc]
  defstruct [:loc, :lastmod]

  @type t :: %__MODULE__{loc: String.t(), lastmod: DateTime.t() | Date.t() | nil}
end
