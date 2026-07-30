# Observability stack (DigitalOcean droplet)

A self-contained monitoring stack layered on top of the app compose project via a
second `-f` file, so Prometheus scrapes app containers **by service name** on the
shared network — no extra wiring.

| Component        | Role                                   | Local port (127.0.0.1) |
| ---------------- | -------------------------------------- | ---------------------- |
| Prometheus       | metrics store + alert rules            | `9090`                 |
| Alertmanager     | alert routing / dedup / silencing      | `9093`                 |
| Node Exporter    | host CPU / mem / disk / net            | _(scraped only)_       |
| cAdvisor         | per-container CPU / mem / net / fs     | _(scraped only)_       |
| Loki             | log store                              | `3100`                 |
| Promtail         | ships container logs → Loki            | _(no UI)_              |
| Tempo            | trace store (OTLP in on 4317/4318)     | `3200`                 |
| Grafana          | dashboards (Prom + Loki + Tempo)       | `3000`                 |

Everything binds to `127.0.0.1` only. Nothing here is exposed to the internet.

> **Langfuse is not in this overlay.** It's an app dependency (the agent tiers
> send LLM traces to it), so it lives in the base stack
> ([../docker-compose.prod.yml](../docker-compose.prod.yml)) and is always on —
> UI at `127.0.0.1:3001`. Only the pure ops tooling above is overlay-gated.

## Run it

```bash
# On the droplet (or locally against deploy/do/.env.production):
ENABLE_MONITORING=true ./deploy.sh          # CD path — folds the overlay in

# Or directly with compose:
docker compose \
  -f docker-compose.prod.yml \
  -f monitoring/docker-compose.monitoring.yml \
  --env-file .env.production up -d

# From the repo root:
make mon-up      # up      ·  make mon-down   # down
make mon-logs    # tail    ·  make mon-ps     # status
```

## Reach the UIs (SSH tunnel — nothing is public)

```bash
ssh -N \
  -L 3000:127.0.0.1:3000 \   # Grafana
  -L 9090:127.0.0.1:9090 \   # Prometheus
  -L 3001:127.0.0.1:3001 \   # Langfuse (base stack)
  deploy@<droplet-ip>
# then open http://localhost:3000  (login: GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD)
```

To expose Grafana on a public subdomain instead, add a block to
[../Caddyfile](../Caddyfile) (Caddy handles TLS) and repoint the container port
away from `127.0.0.1`. Example:

```
monitoring.{$PRODUCTION_HOST} {
    reverse_proxy grafana:3000
}
```

## Wiring the app in

- **Metrics** — expose Prometheus text at `/metrics` on the Go (`:8080`) and
  Python (`:8000`) services. The `aisat-apps` scrape job already targets them
  (reads "down" until they serve it).
- **Traces** — set `OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo:4318` in
  `.env.production` and export OTLP from the app.
- **LLM traces** — set `LANGFUSE_HOST=http://langfuse:3000` plus the
  public/secret keys created in the Langfuse UI (or pre-seed them with the
  `LANGFUSE_INIT_*` block in the **base** `../docker-compose.prod.yml`). Langfuse
  runs whether or not this overlay is enabled.

## Dashboards

`grafana/dashboards/aisat-overview.json` is provisioned automatically. Drop more
JSON into that folder (auto-loaded within 30s) or import these community IDs in
Grafana (**Dashboards → Import**):

| ID      | Dashboard                    |
| ------- | ---------------------------- |
| `1860`  | Node Exporter Full           |
| `19792` | Loki logs / Promtail         |
| `21308` | cAdvisor (container metrics)  |

## Data & retention

Metrics 15d (Prometheus `--storage.tsdb.retention.time`), logs & traces 7d
(`retention_period` in `loki-config.yml`, `block_retention` in `tempo.yml`).
State lives in named volumes (`prometheus_data`, `loki_data`, `tempo_data`,
`grafana_data`, …) — back these up or ship to object storage for durable history.
(Langfuse's `langfuse_pgdata` volume lives with the base stack.)

## Notes

- **Promtail** is in maintenance mode; **Grafana Alloy** is the successor. To
  migrate, swap the `promtail` service for `grafana/alloy` with an equivalent
  `loki.source.docker` → `loki.write` pipeline. The Loki/Grafana side is unchanged.
- **Langfuse** (in the base stack) is the v2 line (Postgres-only). v3
  additionally needs ClickHouse + Redis + S3 — out of scope for a single droplet;
  use the EKS path or Langfuse Cloud for v3.
- Tune alert thresholds in `prometheus/alerts.yml` and enable a real receiver in
  `alertmanager/alertmanager.yml` (Telegram reuse recommended) before relying on it.
