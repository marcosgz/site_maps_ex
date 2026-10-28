defmodule SiteMaps.Config do
  @moduledoc """
  Validated configuration of a sitemap module. Options are given to `use SiteMaps`, read from the
  application environment when `:otp_app` is set, and returned by the optional
  `c:SiteMaps.config/1` callback, in that order of precedence, later sources winning.

  ## Options

  #{NimbleOptions.docs(SiteMaps.Config.Schema.schema())}
  """

  alias SiteMaps.Config.Schema

  @enforce_keys [:url, :root_uri, :index_key, :adapter]
  defstruct [
    :url,
    :root_uri,
    :index_key,
    :adapter,
    :default_changefreq,
    :default_priority,
    :xsl_stylesheet_url,
    :xsl_index_stylesheet_url,
    :tmp_dir,
    gzip?: false,
    max_links: 50_000,
    max_bytes: 50_000_000,
    max_news: 1_000,
    max_index_links: 50_000,
    cache_control: "public, max-age=3600",
    max_concurrency: 1
  ]

  @type t :: %__MODULE__{
          url: String.t(),
          root_uri: URI.t(),
          index_key: String.t(),
          adapter: {module, keyword},
          gzip?: boolean,
          max_links: pos_integer,
          max_bytes: pos_integer,
          max_news: pos_integer,
          max_index_links: pos_integer,
          default_changefreq: atom | nil,
          default_priority: float | nil,
          xsl_stylesheet_url: String.t() | nil,
          xsl_index_stylesheet_url: String.t() | nil,
          cache_control: String.t() | nil,
          max_concurrency: pos_integer,
          tmp_dir: Path.t()
        }

  @doc "Validates `opts` and builds the configuration. Raises on invalid options."
  @spec new!(keyword) :: t
  def new!(opts) do
    opts = NimbleOptions.validate!(opts, Schema.schema())
    uri = URI.parse(opts[:url])

    %__MODULE__{
      url: opts[:url],
      root_uri: %URI{uri | path: Path.dirname(uri.path) |> trailing_slash(), query: nil, fragment: nil},
      index_key: Path.basename(uri.path),
      gzip?: String.ends_with?(uri.path, ".gz"),
      adapter: normalize_adapter(opts[:adapter]),
      max_links: opts[:max_links],
      max_bytes: opts[:max_bytes],
      max_news: opts[:max_news],
      max_index_links: opts[:max_index_links],
      default_changefreq: opts[:default_changefreq],
      default_priority: opts[:default_priority],
      xsl_stylesheet_url: opts[:xsl_stylesheet_url],
      xsl_index_stylesheet_url: opts[:xsl_index_stylesheet_url],
      cache_control: opts[:cache_control],
      max_concurrency: opts[:max_concurrency] || System.schedulers_online(),
      tmp_dir: opts[:tmp_dir] || System.tmp_dir!()
    }
  end

  @doc "Absolute URL of the file stored under `key`."
  @spec key_to_url(t, String.t()) :: String.t()
  def key_to_url(%__MODULE__{root_uri: root}, key) do
    root |> URI.merge(key) |> URI.to_string()
  end

  @doc "Storage key of `url`, or `:error` when the URL is outside the sitemap directory."
  @spec url_to_key(t, String.t()) :: {:ok, String.t()} | :error
  def url_to_key(%__MODULE__{root_uri: root}, url) do
    uri = URI.parse(url)

    with true <- uri.scheme == root.scheme and uri.host == root.host and uri.port == root.port,
         "" <> path <- uri.path,
         true <- String.starts_with?(path, root.path),
         key when key != "" <- String.replace_prefix(path, root.path, "") do
      {:ok, key}
    else
      _ -> :error
    end
  end

  @doc "Resolves a path against the site origin. Absolute `http(s)` URLs are returned unchanged."
  @spec resolve_loc(t, String.t()) :: String.t()
  def resolve_loc(%__MODULE__{}, "http://" <> _ = url), do: url
  def resolve_loc(%__MODULE__{}, "https://" <> _ = url), do: url

  def resolve_loc(%__MODULE__{root_uri: %URI{} = root}, path) do
    %URI{root | path: "/"} |> URI.merge(path) |> URI.to_string()
  end

  defp trailing_slash("/"), do: "/"
  defp trailing_slash(path), do: path <> "/"

  defp normalize_adapter({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  defp normalize_adapter(mod) when is_atom(mod), do: {mod, []}
end
