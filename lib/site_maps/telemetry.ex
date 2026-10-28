defmodule SiteMaps.Telemetry do
  @moduledoc """
  Telemetry events emitted while generating sitemaps.

    * `[:site_maps, :run, :start | :stop | :exception]` - metadata `%{module, context, only}`
    * `[:site_maps, :process, :start | :stop | :exception]` - metadata `%{module, process, args}`
    * `[:site_maps, :urlset, :write]` - measurements `%{links, news, bytes}`,
      metadata `%{module, process, key, url}`
    * `[:site_maps, :index, :write]` - measurements `%{entries, bytes}`, metadata `%{module, key, url}`
    * `[:site_maps, :url, :foreign_host]` - measurements `%{count: 1}`, metadata `%{module, process, loc}`,
      for a URL whose host differs from the sitemap host

  `attach_default_logger/1` logs the `:stop`, `:exception`, `:write` and `:foreign_host` events.
  """

  require Logger

  @handler_id "site-maps-default-logger"

  @events [
    [:site_maps, :run, :stop],
    [:site_maps, :run, :exception],
    [:site_maps, :process, :stop],
    [:site_maps, :process, :exception],
    [:site_maps, :urlset, :write],
    [:site_maps, :index, :write],
    [:site_maps, :url, :foreign_host]
  ]

  @doc "Logs the stop, exception, write and foreign host events at `level` (default `:info`)."
  @spec attach_default_logger(keyword) :: :ok | {:error, :already_exists}
  def attach_default_logger(opts \\ []) do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, Keyword.get(opts, :level, :info))
  end

  @doc "Detaches the handler attached by `attach_default_logger/1`."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event([:site_maps, :run, :stop], %{duration: duration}, meta, level) do
    Logger.log(level, "[site_maps] #{inspect(meta.module)} finished in #{ms(duration)}ms")
  end

  def handle_event([:site_maps, kind, :exception], _measurements, meta, _level) do
    Logger.error("[site_maps] #{kind} failed: " <> Exception.format(meta.kind, meta.reason, meta.stacktrace))
  end

  def handle_event([:site_maps, :process, :stop], %{duration: duration}, meta, level) do
    Logger.log(level, "[site_maps] process #{meta.process} #{inspect(meta.args)} done in #{ms(duration)}ms")
  end

  def handle_event([:site_maps, :urlset, :write], measurements, meta, level) do
    Logger.log(level, "[site_maps] wrote #{meta.url} (#{measurements.links} links, #{measurements.bytes} bytes)")
  end

  def handle_event([:site_maps, :index, :write], measurements, meta, level) do
    Logger.log(level, "[site_maps] wrote index #{meta.url} (#{measurements.entries} entries)")
  end

  def handle_event([:site_maps, :url, :foreign_host], _measurements, meta, _level) do
    Logger.warning("[site_maps] #{meta.loc} is not on the sitemap host and may be ignored by crawlers")
  end

  defp ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
