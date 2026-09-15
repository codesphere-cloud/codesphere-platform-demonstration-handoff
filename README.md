# Codesphere Platform Demonstration

A small TanStack Start application with Codesphere landscape definitions for a
development and QA setup.

## Contents

- `demo-app/`: TanStack Start application using Drizzle ORM and Postgres.
- `ci.dev.yml` and `ci.qa.yml`: Codesphere landscape definitions. The dev
  profile runs Vite with hot reload; the QA profile builds and serves the
  compiled app.
- `infrastructure/`: Local Postgres setup for development, the Codesphere
  startup script used by deployed landscapes, and the preview-deployment
  scaffolding script (`infrastructure/preview/`).
- `.github/workflows/preview-deployment.yml`: Creates a Codesphere preview
  workspace per pull request and tears it down on close.

## Local Development

Local development runs the app on your machine. Docker Compose provides the
Postgres database, and Vite serves the app in development mode.

The Codesphere landscapes use `ci.dev.yml`, `ci.qa.yml`, and
`infrastructure/codesphere/start-app.sh` instead of the local `.env.local` file.

### Prerequisites

Only three things need to exist on your machine before mise takes over:

- [mise](https://mise.jdx.dev/) — manages Node `22.22.2`, pnpm `9.15.9`, `jq`,
  and `gh`, all pinned in `.mise.toml`. Nothing else needs to be
  brew/apt-installed for local dev or for `infrastructure/preview/scaffold.sh`.
- [direnv](https://direnv.net/) — auto-activates the mise toolchain (and
  loads `demo-app/.env.local` if present) whenever you `cd` into the repo,
  via the committed `.envrc`.
- Docker (with the Compose v2 plugin) — used only for the local Postgres
  database. This is the one dependency mise/direnv can't provide; everything
  else in this repo assumes it's already running.

Install mise and direnv once, then from the repo root:

```bash
direnv allow   # trust .envrc — activates the pinned toolchain from here on
mise install   # fetch node, pnpm, jq, gh at the pinned versions
mise run doctor
```

`mise run doctor` (`infrastructure/dev/doctor.sh`) checks every dependency
above — pinned tool versions, direnv activation, and the Docker daemon — and
prints a specific, actionable message for anything missing before you go any
further.

### First-Time Setup

```bash
cp demo-app/.env.example demo-app/.env.local   # edit if you change the Postgres port
pnpm install
pnpm dev:up          # start Postgres on localhost:5433
pnpm db:migrate      # apply committed Drizzle migrations
pnpm db:seed:dev     # optional sample messages
pnpm dev             # start the app at http://localhost:3000
```

With mise, `mise run setup` runs `doctor` first, then install, starts
Postgres, and applies migrations. Then run `mise run dev`.

`demo-app/.env.local` is gitignored. It provides `DATABASE_URL` and
`APP_BASE_URL` for local app and Drizzle CLI commands.

### Daily Workflow

Postgres data persists in a Docker volume between restarts. After the first
setup, the usual local workflow is:

```bash
pnpm dev:up
pnpm dev
```

Use `pnpm dev:down` to stop Postgres and keep the data volume. Use
`pnpm dev:reset` to stop Postgres and delete the volume, then run
`pnpm db:migrate` again.

### Commands

- `pnpm dev`: Starts the Vite dev server for `demo-app/` on port `3000`.
- `pnpm build`: Builds the production app into `demo-app/.output/`.
- `pnpm start`: Runs the built Nitro server. Run `pnpm build` first.
- `pnpm test`: Runs Vitest unit tests. No database is required.
- `pnpm typecheck`: Runs `tsc --noEmit` for `demo-app/`.
- `pnpm dev:up`: Starts local Postgres from
  `infrastructure/dev/docker-compose.yml`.
- `pnpm dev:down`: Stops local Postgres and keeps the data volume.
- `pnpm dev:reset`: Stops local Postgres and deletes the data volume.
- `pnpm dev:logs`: Tails the Postgres container logs.
- `pnpm db:migrate`: Applies migrations. Requires Postgres and `.env.local`.
- `pnpm db:generate`: Generates a migration after schema changes.
- `pnpm db:seed:dev`: Inserts sample messages if the table is empty.

### Quality Checks

Run the same checks used before the app starts in Codesphere:

```bash
pnpm typecheck && pnpm test && pnpm build
```

To smoke-test the production build locally:

```bash
pnpm build
DATABASE_URL=postgresql://demo_app:demo_app@localhost:5433/demo_app \
APP_BASE_URL=http://localhost:3000 \
pnpm start
```

Then open http://localhost:3000 and
http://localhost:3000/api/health/live.

### Troubleshooting

**Not sure what's missing?** Run `mise run doctor` — it checks mise, direnv,
pinned tool versions, and the Docker daemon in one pass.

**Port 5433 is already in use.** Another local Postgres container may be using
the port. Stop that container or override the host port:

```bash
DEMO_POSTGRES_PORT=5435 pnpm dev:up
```

Then update `DATABASE_URL` in `demo-app/.env.local` to use the same port.

**`pnpm dev:up` fails with "permission denied" on the Docker socket.** Start
Docker Desktop or the Docker daemon.

**Migrations fail or connection is refused.** Start Postgres with
`pnpm dev:up` and check that `.env.local` points at the right port.

## Preview Deployments

Every pull request gets its own Codesphere workspace, deployed from
`ci.dev.yml` (Vite dev server, hot reload, seeded sample data). The workspace
is created on PR open/sync and deleted when the PR is closed or merged. See
`.github/workflows/preview-deployment.yml`.

### One-time setup

The workflow needs a GitHub secret, two GitHub variables, and a Codesphere
team shared vault. `infrastructure/preview/scaffold.sh` provisions all of it
from one local, gitignored env file — you do not need to click through the
GitHub or Codesphere UIs by hand.

1. Create a Codesphere **service account** (a dedicated machine user, e.g.
   `devops+ci@yourdomain.com`), invite it to your target team, and connect it
   to this GitHub repository with Git permissions.
2. Generate an API token for that service account: Codesphere > Account
   Settings > API Keys.
3. Copy the env template and fill it in:

   ```bash
   cp infrastructure/preview/preview.env.example infrastructure/preview/preview.env
   # edit infrastructure/preview/preview.env: set CS_TOKEN and CS_TEAM_NAME at minimum
   ```

4. Run the scaffolding script (requires `gh` authenticated — `gh auth login`
   — plus `curl` and `openssl`, both system-provided; `gh` and `jq` come from
   mise, see Prerequisites above, and `mise run doctor` checks all of it):

   ```bash
   bash infrastructure/preview/scaffold.sh
   ```

   This sets the GitHub secret `CS_TOKEN` and variables `CS_TEAM_NAME`,
   `CS_SHARED_VAULT`, `CODESPHERE_INSTANCE_URL`; creates the Codesphere team
   shared vault named by `CS_SHARED_VAULT` if it does not exist; and stores
   the `POSTGRES_PASSWORD` / `POSTGRES_SUPERUSER_PASSWORD` secrets that
   `ci.dev.yml` references (generating strong random values if you left them
   blank in `preview.env`). It is safe to re-run — existing values are left
   alone unless you set `FORCE=1`.
5. Open a pull request. The workflow validates all of the above (failing
   with a clear error if anything is missing or invalid) before deploying,
   then posts the preview link on the PR.

`infrastructure/preview/preview.env` holds a live API token — never commit
it (it is already gitignored).
