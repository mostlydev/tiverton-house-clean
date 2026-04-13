# Public Routing Split

The public host should expose only the server-rendered dashboard surface.

- Allow public routes: `/`, `/dashboard/*`, `/trader/*`, `/research/*`, `/notes/*`, `/assets/*`, `/rails/active_storage/*` only if needed, and normal Rails asset paths.
- Block public routes: `/api/v1/*`, `/admin/*`, and any legacy dashboard JSON compatibility paths.
- Prefer a separate public web process with no Alpaca credentials, no trading API tokens, and read-only data access.

Example Caddy shape:

```caddy
<public-site-hostname> {
  @public path / /dashboard/* /trader/* /research/* /notes/* /assets/* /up
  reverse_proxy @public trading-web:4000

  respond /api/* 404
  respond /admin/* 404
}

<internal-api-hostname> {
  reverse_proxy trading-api:4000
}
```

If the same Rails process is serving both surfaces temporarily, keep the browser on the SSR/Hotwire routes and avoid exposing any JSON control-plane endpoints on the public host.
