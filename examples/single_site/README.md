# SingleSite

A Phoenix app serving the sitemaps of one site, using [site_maps](../../README.md). It depends on
the package through `{:site_maps, path: "../.."}`.

This is the common setup: one module, no `config/1` callback and no context. The options come
from `use SiteMaps` and the application environment.

## Running

```
mix setup
mix sitemaps   # static pages and every month of the year
mix test
mix phx.server
```

Then open http://localhost:4000/sitemap.xml (the stylesheet renders it in the browser), a shard
such as `/posts/2026-1/sitemap1.xml`, and `/robots.txt`.

Regenerate one month from the command line:

```
mix site_maps.generate SingleSite.Sitemaps posts --arg year=2026 --arg month=3
```

The rest of the index is kept.

## Where to look

- `lib/single_site/sitemaps.ex`: the sitemap module.
  - `use SiteMaps, otp_app: :single_site, adapter: ...` sets the storage and reads the rest from the app env.
  - It declares the `static` and `posts` (one shard per month) processes.
  - `backfill/0` regenerates every month of the year, with pruning.
- `config/config.exs`: the sitemap URL. `config/runtime.exs` switches it to `https://$PHX_HOST/sitemap.xml.gz` in production, and `config/test.exs` points the adapter to `tmp/test_sitemaps`.
- `lib/single_site/blog.ex`: deterministic fake posts.
- `lib/single_site_web/endpoint.ex`: `plug SiteMaps.Plug, sitemaps: {SingleSite.Sitemaps, %{}}` before the router.
- `lib/single_site_web/controllers/site_controller.ex`: `robots.txt` built with `SiteMaps.RobotsTxt`.
- `lib/mix/tasks/sitemaps.ex`: `mix sitemaps`, with the default telemetry logger.
- `test/single_site_web/sitemaps_test.exs`: the index, a shard, `robots.txt`, stylesheets, 404s, and an incremental run that keeps the rest of the index.

Serving several sites from one app is covered by [`examples/two_tenants`](../two_tenants/README.md)
and, for host to site to theme Phoenix apps, by
[multitenancy_phoenix](https://github.com/marcosgz/multitenancy_phoenix).
