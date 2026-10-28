# TwoTenants

A Phoenix app serving sitemaps for two tenants from one sitemap module, using
[site_maps](../../README.md). It depends on the package through `{:site_maps, path: "../.."}`.
For real host→site→theme apps, see [multitenancy_phoenix](https://github.com/marcosgz/multitenancy_phoenix).

| Host                  | Tenant   |
| --------------------- | -------- |
| `acme.localtest.me`   | `acme`   |
| `globex.localtest.me` | `globex` |
| anything else         | 404      |

`*.localtest.me` resolves to `127.0.0.1`, so `/etc/hosts` needs no changes.

## Running

```
mix setup
mix two_tenants.sitemaps   # every tenant: static, news and every month of the year
mix test
mix phx.server
```

Then open http://acme.localtest.me:4000/sitemap.xml (the stylesheet renders it in the
browser), a shard such as `/posts/2026-1/sitemap1.xml`, and `/robots.txt`.

Regenerate one month of one tenant from the command line:

```
mix site_maps.generate TwoTenants.Sitemaps posts --context tenant=acme --arg year=2026 --arg month=3
```

The rest of acme's index is kept, and the other tenant is untouched.

## Where to look

- `lib/two_tenants/sitemaps.ex`: the sitemap module.
  - `config/1` builds the URL and storage directory for each tenant.
  - It declares the `static`, `posts` (one shard per month) and `news` processes.
  - `load_context/1` turns the CLI's `tenant=acme` into the tenant.
  - `backfill/1` regenerates every month of the year, with pruning.
- `lib/two_tenants/tenants.ex`: the two tenants and their deterministic fake posts.
- `lib/two_tenants_web/endpoint.ex`: `SiteMaps.Plug` placed before the router. It resolves `{TwoTenants.Sitemaps, %{tenant: tenant}}` from the host.
- `lib/two_tenants_web/controllers/site_controller.ex`: `robots.txt` built with `SiteMaps.RobotsTxt`.
- `lib/mix/tasks/two_tenants.sitemaps.ex`: generates every tenant, with the default telemetry logger.
- `priv/sitemaps/<tenant>/`: generated files, via the FileSystem adapter. Tests write to `tmp/test_sitemaps`.
- `test/two_tenants_web/sitemaps_test.exs`: each host's index and shards, isolation between tenants, news, `robots.txt`, stylesheets, 404s, and an incremental run that keeps the rest of the index.
