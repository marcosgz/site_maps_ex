defmodule SiteMaps.Config.Schema do
  @moduledoc false

  @changefreqs ~w(always hourly daily weekly monthly yearly never)a

  def schema do
    NimbleOptions.new!(
      url: [
        type: {:custom, __MODULE__, :validate_url, []},
        required: true,
        doc: "Public URL of the sitemap index. Ending in `.xml.gz` gzips every file."
      ],
      adapter: [
        type: {:or, [:atom, {:tuple, [:atom, :keyword_list]}]},
        required: true,
        doc: "Storage adapter, `Module` or `{Module, opts}`."
      ],
      max_links: [type: {:in, 1..50_000}, default: 50_000, doc: "URLs per sitemap file."],
      max_bytes: [
        type: {:in, 1..52_428_800},
        default: 50_000_000,
        doc: "Uncompressed bytes per sitemap file."
      ],
      max_news: [type: {:in, 1..1_000}, default: 1_000, doc: "News URLs per sitemap file."],
      max_index_links: [type: {:in, 1..50_000}, default: 50_000, doc: "Entries in the index."],
      default_changefreq: [type: {:in, [nil | @changefreqs]}, default: nil, doc: "`<changefreq>` for URLs without one."],
      default_priority: [
        type: {:custom, __MODULE__, :validate_priority, []},
        default: nil,
        doc: "`<priority>` for URLs without one."
      ],
      xsl_stylesheet_url: [type: {:or, [:string, nil]}, default: nil, doc: "XSL stylesheet of urlsets."],
      xsl_index_stylesheet_url: [type: {:or, [:string, nil]}, default: nil, doc: "XSL stylesheet of the index."],
      cache_control: [
        type: {:or, [:string, nil]},
        default: "public, max-age=3600",
        doc: "Cache-Control stored with files."
      ],
      max_concurrency: [
        type: {:or, [:pos_integer, nil]},
        default: nil,
        doc: "Processes run in parallel. Defaults to schedulers online."
      ],
      tmp_dir: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Directory for files being built. Defaults to `System.tmp_dir!/0`."
      ]
    )
  end

  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] or is_nil(uri.host) ->
        {:error, "expected an absolute http(s) URL, got: #{inspect(url)}"}

      not String.ends_with?(uri.path || "", [".xml", ".xml.gz"]) ->
        {:error, "expected the URL to end with .xml or .xml.gz, got: #{inspect(url)}"}

      true ->
        {:ok, url}
    end
  end

  def validate_url(other), do: {:error, "expected a URL string, got: #{inspect(other)}"}

  def validate_priority(nil), do: {:ok, nil}
  def validate_priority(p) when is_number(p) and p >= 0 and p <= 1, do: {:ok, p / 1}
  def validate_priority(p), do: {:error, "expected a priority between 0.0 and 1.0, got: #{inspect(p)}"}
end
