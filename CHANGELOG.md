# Changelog

## 0.1.0

First release. An Elixir port of the [site_maps](https://github.com/marcosgz/site_maps) Ruby gem:

- Sitemap modules with `use SiteMaps`, `process` declarations and stream-returning `urls/3` callbacks
- Options from `use SiteMaps`, the application environment (`otp_app:`, read at runtime) and the optional `config/1` callback for per-site settings
- Files rotate at the protocol limits (50,000 URLs, 50 MB uncompressed, 1,000 news URLs), optional gzip
- Parallel processes, incremental index merges and pruning of stale shard files
- Image, video, news, alternate (hreflang), mobile and PageMap extensions, validated against the XSDs
- Storage adapters: file system (atomic writes, NFS friendly), S3 and S3-compatible stores, Cloudflare R2, memory and noop
- `SiteMaps.Plug` to serve sitemaps and XSL stylesheets, `SiteMaps.RobotsTxt`
- `mix site_maps.generate`, `mix site_maps.gen` (single-site by default, `--multi` for several sites) and an optional `SiteMaps.Oban.Worker`
- Telemetry events with a default logger
- Example Phoenix apps: `examples/single_site` and `examples/two_tenants`
