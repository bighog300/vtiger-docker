# vtiger-docker

Docker packaging for [vtiger CRM 8.3.0](https://github.com/bighog300/vtigercrm) on PHP 8.3 (Debian Bookworm).

The build produces a minimal runtime image (`ghcr.io/bighog300/vtigercrm`) containing
the vtiger source, compiled PHP extensions, and a baked-in schema dump used for
first-start database initialisation.

## How it works

| Stage | Purpose |
|-------|---------|
| `builder` | Installs PHP extensions, clones vtiger source, runs headless installer |
| `runtime` | Minimal image: Apache + PHP + app files + `schema.sql` |

The installer runs against a temporary MySQL container, populates the database, then
`mysqldump` exports `schema.sql` into the workspace. The Dockerfile's `runtime` stage
copies `schema.sql` into the image. The runtime entrypoint imports the schema on first
start if the target database is empty.

## Local build

**Prerequisites:** Docker 24+, Docker Compose v2, ~4 GB disk space.

```bash
# Full pipeline: MySQL → installer → schema export → runtime image
./build.sh --no-push
```

This builds and tags `vtigercrm-local:8.3.0` locally by default when `--no-push` is used.
To use a different local image name:

```bash
IMAGE=vtigercrm-local VERSION=8.3.0 ./build.sh --no-push
```

The pipeline steps:
1. Start a temporary MySQL container (`vtiger-build-mysql`)
2. Build the `builder` stage and run the headless installer
3. Dump `schema.sql` via `mysqldump`
4. Tear down the build stack
5. Build the `runtime` image with `schema.sql` baked in

## Important build note

`schema.sql` is intentionally generated during `./build.sh --no-push`.
A plain `docker build .` or `docker compose build` will fail until that file exists,
because the runtime image bakes the generated schema into `/opt/vtiger/schema.sql`.

## Local smoke test

After running `build.sh --no-push` with the default local image name:

```bash
docker compose up -d
```

Open <http://localhost:8080> and log in with `admin` / `Admin@1234`.

If you built a custom local image name, run:

```bash
IMAGE=vtigercrm-local VERSION=8.3.0 ./build.sh --no-push
docker compose up -d
```

Tear down:
```bash
docker compose down -v
```

## Build only the installer image

Useful to verify the builder stage compiles without running the full pipeline:

```bash
docker compose -f docker-compose.build.yml build installer
```

## GitHub Actions

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | PR, `workflow_dispatch` | Lint, full build, install, schema verify, smoke test |
| `publish.yml` | Push to `main`, `v*` tags, `workflow_dispatch` | Build installer, run full schema-generation pipeline, then publish runtime image to GHCR |
| `nightly.yml` | Weekly Mon 03:00 UTC, `workflow_dispatch` | Scheduled full smoke test |

### Publish behaviour

| Event | Tags published |
|-------|---------------|
| Push to `main` | `latest`, `sha-<hash>` |
| Push tag `v8.3.0` | `8.3.0`, `8.3`, `sha-<hash>` |

Only the `runtime` stage is published. The `builder` stage is not pushed.

## Required GitHub repository settings

1. **Actions → General → Workflow permissions** — allow `GITHUB_TOKEN` to write packages (`packages: write`).
2. **GHCR package linkage** — if push fails with `permission_denied: write_package`, open the existing package settings and connect it to this repository so Actions can publish to it.
3. **Package visibility** — after the first publish, visit
   `https://github.com/users/bighog300/packages/container/vtigercrm/settings`
   and set visibility to *Public* if desired.
4. **Secrets** — no additional secrets are required; `GITHUB_TOKEN` is sufficient
   for pushing to GHCR.

## Environment variables (runtime)

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | `mysql` | MySQL hostname |
| `DB_PORT` | `3306` | MySQL port |
| `DB_NAME` | `vtiger` | Database name |
| `DB_USER` | `vtiger` | App database user |
| `DB_PASSWORD` | `vtigerpass` | App database password |
| `DB_ROOT_PASSWORD` | `root` | MySQL root password (used during schema import) |
| `VTIGER_SITE_URL` | `http://localhost:8080` | Public URL for the vtiger application |
| `VTIGER_ADMIN_USER` | `admin` | Admin login username |
| `VTIGER_ADMIN_PASSWORD` | `Admin@1234` | Admin login password |
| `VTIGER_ADMIN_EMAIL` | `admin@example.com` | Admin email address |
| `VTIGER_TIMEZONE` | `UTC` | Application timezone |
| `VTIGER_LANGUAGE` | `en_us` | Default language |
| `VTIGER_CURRENCY` | `USD` | Default currency |
| `VTIGER_COMPANY_NAME` | `VEMS` | Company name shown in the UI |

## Browser installer flow

To build the vtiger web image from `https://github.com/bighog300/vtigercrm` and launch the UI installer without running the headless automation:

```bash
./install-ui.sh
```

Then open:

```text
http://localhost:8080/index.php?module=Install&view=Index
```

Optional overrides:

```bash
VTIGER_REPO_REF=main APP_PORT=8081 ./install-ui.sh
```
