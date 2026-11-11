# Changelog

## 0.2.0

- `index_from_storage` option: the stored files of every declared process are listed in the index, so files missing from it (e.g. after a failed run) are listed again. A failing process no longer stops the run: the other processes keep running, the successful ones are published, and the first error is returned. Files of failed processes are never pruned.
- `SiteMaps.rebuild_index/2` rewrites the index from storage without running any process.
- `[:site_maps, :rebuild_index, :start | :stop | :exception]` telemetry events.

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
