# CI/CD Setup — GitHub Actions → Docker Hub → DigitalOcean Droplet (Telegram alerts)

This repo ships a production-grade pipeline that stays **inert until code lands** and
lights up per runtime (Go / Python / React) as each appears.

```
 PR / push ──► CI  (lint · test · vuln-scan · secret-scan · Dockerfile-lint)      [ci.yml]
 push main ──► CD  discover ─► build+push images (Docker Hub, SBOM+provenance)    [cd.yml]
                              └─► ⛔ approval gate (production environment)
                                   └─► scp deploy/do/ ─► droplet: pull · migrate · up · health
                                        └─► rollback on failure ─► Telegram ✅/❌
```

Only the **deploy** step is gated: it pauses on the protected `production` environment
until a reviewer approves. CI runs on every PR and push regardless.

> **Deploying to AWS EKS instead of / in addition to the droplet?** See
> [eks/SETUP.md](./eks/SETUP.md) — a parallel pipeline (`cd-eks.yml`) that builds to
> Amazon ECR and deploys a Helm release to EKS via OIDC. It runs alongside this one;
> neither replaces the other.

---

## 1. Docker Hub

1. Create the repos (or let the first push create them): `aisat-backend-go`,
   `aisat-backend-python`, `aisat-frontend`. (No `aisat-crawl` — the crawl role now
   runs from `aisat-backend-python` as a thin orchestrator over the sandbox tier.)
2. **Account → Security → New Access Token** (Read/Write). Save it for `DOCKERHUB_TOKEN`.

## 2. DigitalOcean droplet

Create an Ubuntu 22.04/24.04 droplet (2 vCPU / 4 GB is a sane starting size), point a
DNS **A record** (`PRODUCTION_HOST`) at its IP, then bootstrap it:

```bash
ssh root@<droplet-ip> 'bash -s' < deploy/do/bootstrap-droplet.sh
```

That installs Docker + Compose, creates the `deploy` user, opens 22/80/443, and prepares
`/opt/aisat-intel`. Then, as documented in the script output:

```bash
# a) create a dedicated deploy SSH key (run locally)
ssh-keygen -t ed25519 -f ./aisat_deploy -C "aisat-cd" -N ""
ssh-copy-id -i ./aisat_deploy.pub deploy@<droplet-ip>   # public key -> droplet
#    -> put the PRIVATE key (aisat_deploy) into GitHub secret DROPLET_SSH_KEY

# b) create the production env file on the droplet (never committed)
scp deploy/do/.env.production.example deploy@<droplet-ip>:/opt/aisat-intel/do/.env.production
ssh deploy@<droplet-ip> 'chmod 600 /opt/aisat-intel/do/.env.production && $EDITOR ...'

# c) let Docker pull your images
ssh deploy@<droplet-ip> 'docker login -u <DOCKERHUB_USERNAME>'
```

## 3. Telegram notifications

1. Message **@BotFather** → `/newbot` → copy the **bot token** → `TELEGRAM_BOT_TOKEN`.
2. Get your **chat id**: send any message to the bot, then open
   `https://api.telegram.org/bot<token>/getUpdates` and read `result[].message.chat.id`
   (for a group, add the bot to it first; ids are negative). → `TELEGRAM_CHAT_ID`.

## 4. GitHub configuration

**Settings → Secrets and variables → Actions → Variables:**

| Variable             | Example              | Used for                              |
| -------------------- | -------------------- | ------------------------------------- |
| `DOCKERHUB_USERNAME` | `truongpx396`        | image namespace + registry login user |
| `PRODUCTION_HOST`    | `app.example.com`    | environment URL + Caddy TLS host      |

**Settings → Secrets and variables → Actions → Secrets:**

| Secret                | Notes                                                     |
| --------------------- | -------------------------------------------------------- |
| `DOCKERHUB_TOKEN`     | Docker Hub access token (step 1)                         |
| `DROPLET_HOST`        | droplet IP or hostname                                   |
| `DROPLET_USER`        | `deploy`                                                 |
| `DROPLET_SSH_KEY`     | the **private** deploy key (step 2a)                     |
| `DROPLET_SSH_PORT`    | optional; defaults to `22`                               |
| `TELEGRAM_BOT_TOKEN`  | from @BotFather                                          |
| `TELEGRAM_CHAT_ID`    | target chat id                                           |

**Settings → Environments → `production`:** add **Required reviewers** (yourself) — this
is the approval gate. Optionally restrict deploys to the `main` branch.

**Settings → Branches:** protect `main` and mark the **`ci-gate`** check as required.

## 5. First deploy

Push to `main` (or **Actions → CD → Run workflow**). CD builds + pushes images, then waits
on the `production` approval. Approve it → the droplet pulls, migrates, and starts. You'll
get a Telegram message on start, success, or failure.

**Redeploy / rollback:** Actions → CD → **Run workflow** and pass an earlier commit SHA as
`image_tag`. The droplet also **auto-rolls-back** to the last good tag if a fresh deploy
fails its health check.

---

## Monitoring (optional overlay)

A full observability stack — **Prometheus, Grafana, cAdvisor, Node Exporter,
Loki, Tempo, Alertmanager, Promtail** — ships as a compose overlay in
[monitoring/](./monitoring/). It layers onto the same compose project, so
Prometheus scrapes app containers by service name with no extra wiring.

```bash
# opt in on the droplet by setting the CD env var (or run make mon-up locally):
ENABLE_MONITORING=true ./deploy.sh
```

Every UI binds to `127.0.0.1` only — reach them over an SSH tunnel (or front
Grafana with Caddy). Set `GRAFANA_ADMIN_PASSWORD` in `.env.production` before
enabling the overlay. Full details, ports, dashboards, and app wiring:
[monitoring/README.md](./monitoring/README.md).

> **Langfuse** (LLM tracing) is **not** in this overlay — it's an app dependency,
> so it runs in the base stack and is always on. That makes
> `LANGFUSE_DB_PASSWORD`, `LANGFUSE_NEXTAUTH_SECRET`, and `LANGFUSE_SALT` required
> for every deploy (set them in `.env.production`, overlay or not).

---

## Integration contracts (what the app code must provide)

The pipeline assumes the structure in [specs/001-contextengine-mvp/plan.md](../../specs/001-contextengine-mvp/plan.md):

- **`backend-go/`** — `go.mod`, `cmd/{api,relay,worker}`, and the binary exposes a
  `healthcheck` subcommand and a `migrate up` subcommand; serves `/livez` + `/readyz` on `:8080`.
- **`backend-python/`** — `pyproject.toml` + `uv.lock`; `uvicorn src.main:app` serves `/livez`
  on `:8000`; `python -m src.worker` and `python -m src.mcp_server.server` roles exist; a
  `src.services.ingestion.crawl_orchestrator` module (the crawl role drives crawl4ai inside a
  sandbox microVM over the `Sandbox` port — the `crawl`/`convert` toolchains ship as microVM
  templates in [deploy/sandbox/templates/](../sandbox/templates/), not this image).
- **`frontend/`** — `package.json` with `build` (and ideally `lint`/`typecheck`/`test`) scripts;
  Vite emits to `dist/`.
- Confirm the SSE path prefixes in [deploy/do/Caddyfile](./Caddyfile) against
  `specs/001-contextengine-mvp/contracts/{bff-rest,sse-events}.md`.

## Production hardening checklist

Per [.github/instructions/devops-cicd.instructions.md](../../.github/instructions/devops-cicd.instructions.md),
tighten these before real traffic:

- [ ] **Pin actions to commit SHAs** (`ratchet pin .github/workflows/*.yml`); Dependabot maintains them.
- [ ] **Pin base + service images by `@sha256` digest** (Dockerfiles + `docker-compose.prod.yml`);
      verify the floating tags (`litellm:main-stable`, `minio`, `casdoor`) against known-good releases.
- [ ] **Make image CVEs blocking**: set `exit-code: '1'` on the Trivy steps in `ci.yml` / `cd.yml`.
- [ ] Move backing stores to **managed services** (DO Managed Postgres/Redis) or add off-box backups
      for the `pgdata` / `qdrantdata` / `miniodata` volumes.
- [ ] Rotate `DOCKERHUB_TOKEN` / `DROPLET_SSH_KEY` / provider keys on a schedule.
- [ ] Tighten the Caddy CSP header for the SPA once the asset origins are known.
```
