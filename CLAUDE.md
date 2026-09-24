# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

`jarvis-engineer` builds a Docker sandbox **template image** for running specialized Claude Code
agents ("kits") — coder, refactorer, reviewer, expert, investigator, planner, and architect. Each
kit is a persona (a system-prompt markdown file) plus an `sbx` sandbox spec (`spec.yaml`) that
provisions the sandbox: network allowlist, an `ai-memory` MCP server on a persistent volume, and a
read-only MySQL MCP server tunneled in from the host.

The Go module (`main.go`) is a separate, much smaller piece: a coder/reviewer iteration loop that
shells out to the `claude` CLI directly (not via `sbx`). See "Known gaps" below — it currently
references files that don't exist in this repo.

## Commands

### Go module

- `go build` — compile
- `go test ./...` — run tests (there are none yet)
- `go vet` — static checks
- `go run main.go <task>` — run the coder/reviewer loop (see Known gaps; not currently functional)

### Docker image / sandbox template (`Makefile`)

- `make build` — build the `jarvis-engineer:latest` image
- `make verify-image` — static acceptance checks against the built image (`scripts/verify-image.sh`)
- `make verify-kits` — static acceptance checks against every `agents/*/spec.yaml` (`scripts/verify-kits.sh`)
- `make verify` — both of the above
- `make template` — build + verify-image, then save/load the image into `sbx` as a reusable template
- `make sandbox [KIT=agents/coder] [SANDBOX=jarvis-coder]` — (re)create a named sandbox from a kit,
  reading MySQL credentials from `.env`, then run `scripts/verify-sandbox.sh` against it
- `make verify-sandbox [SANDBOX=jarvis-coder]` — live checks against an already-running sandbox
- `make clean` — remove the build tarball

Running the verify scripts directly:

- `./scripts/verify-image.sh [image]` — needs `docker`, `jq`
- `./scripts/verify-kits.sh` — needs the `sbx` CLI (runs `sbx kit validate` / `sbx kit inspect` per kit)
- `./scripts/verify-sandbox.sh <sandbox-name>` — needs a live `sbx` sandbox and `sbx exec`

`.dockerignore` excludes `scripts/` and then re-includes only the two scripts the image installs
(`install-claude-plugins.sh`, `restore-claude-plugins.sh`); a new script the Dockerfile `COPY`s
fails the build with "not found" until it is listed there too.

`.env` (git-ignored) holds `MYSQL_HOST`/`MYSQL_PORT`/`MYSQL_USER`/`MYSQL_PASS` and is only ever
passed with `--env-file .env` at `sbx create` time — never baked into the image or written into a
kit spec.

## Architecture

### Image (`Dockerfile`)

Built from `docker/sandbox-templates:claude-code-docker` (gives the sandbox a real nested Docker
daemon, not just the CLI). On top of that, as root:

- installs a version-pinned `ai-memory` binary (via `mise`, `AI_MEMORY_VERSION` in the Dockerfile)
  to `/usr/local/bin/ai-memory` — copied rather than symlinked so the path baked into
  `~/.claude/settings.json` survives a later version bump
- installs `@benborla29/mcp-server-mysql` globally
- bakes the Claude Code plugins listed in `config.json` via `scripts/install-claude-plugins.sh`,
  run as the `agent` user (uid 1000) so `installPath` entries in the plugin cache are readable by
  the sandbox's actual runtime user
- snapshots the two settings keys that install writes (`enabledPlugins`,
  `extraKnownMarketplaces`) to `/usr/local/share/jarvis-engineer/plugin-settings.json`, and
  installs `scripts/restore-claude-plugins.sh` as `/usr/local/bin/restore-claude-plugins`. This
  exists because `sbx create` writes `~/.claude/settings.json` from scratch (permissions, model):
  the plugin _cache_ under `~/.claude/plugins` survives from the image, but the settings keys that
  load it do not, so without the restore step every baked plugin comes up `"enabled": false`.
  The snapshot is taken from the resolved settings rather than derived from `config.json`, because
  a marketplace's _name_ comes from its own manifest, not from its repo path
  (`mattpocock/skills` resolves to the marketplace `mattpocock`).

- installs `scripts/jarvis-statusline.sh` as `/usr/local/bin/jarvis-statusline`. It both renders
  the status line (`ROLE | Model | directory | branch`) and, with `--install`, points
  `~/.claude/settings.json` at itself. `statusLine` is settings-only state, so like the plugin
  keys it is lost on every `sbx create` and has to be re-registered by a startup step; the script
  it points at must therefore live outside `$HOME`.

Every install is asserted at build time (not just "exit 0"), and again by `verify-image.sh`,
because a sandbox's `~/.claude` is recreated fresh on every `sbx create` — anything installed by
hand outside the image is lost, so "does it survive a fresh sandbox" is the real bar.

### Kits (`agents/<name>/spec.yaml` + `agents/<name>/files/home/<name>.md`)

Each kit extends the built-in `claude` sandbox, points `sandbox.image` at
`jarvis-engineer:latest`, and appends the persona file as the system prompt
(`--append-system-prompt-file /home/agent/<name>.md`). All seven kits have a `spec.yaml`.

Two things about the persona files are worth knowing before editing them:

- The YAML frontmatter (`name`, `description`, `skills`) is **advisory prose, not a binding**.
  `--append-system-prompt-file` appends the file as raw text, so the frontmatter arrives as literal
  YAML inside the system prompt. Nothing preloads the listed skills and nothing errors on a name
  that does not exist — which is how four kits came to reference a `karpathy-guidelines` skill that
  is in neither marketplace in `config.json`. If you add a `skills:` entry, confirm the skill is
  actually installed by the image.
- The read-only roles (`reviewer`, `investigator`, `planner`, `expert`, `architect`) are enforced
  **only by the prompt**. Every spec grants the same unrestricted tool set; nothing at the sandbox
  layer stops those kits from editing files. Treat "read-only" in a description as intent, not a
  guarantee.

Each kit also ships `files/home/.jarvis-role` — a single line such as `CODER` — which is the
static role label the status line renders. It is a file rather than an `environment.variables`
entry because `verify-kits.sh` byte-compares that block across kits, so a per-kit value there
reads as drift. `$JARVIS_ROLE` overrides it; with neither, the line falls back to `AGENT`.

The network allowlist is split into a base block shared by every kit and a `registry.npmjs.org` /
`registry.yarnpkg.com` addition for the two kits that resolve dependencies (`coder`, `refactorer`).
`verify-kits.sh` asserts the base is complete per kit, because the `permissions:` block sits above
the shared block and is invisible to the drift comparison.

All seven specs duplicate the same block verbatim (this is intentional, not an oversight —
`extends` only resolves _built-in_ agents, so pointing it at a local kit for de-duplication
resolves to an empty parent while `sbx kit validate` still reports `VALID`):

- an `AI_MEMORY_DATA_DIR` volume at `/var/lib/ai-memory` (chowned to uid 1000 on install, since
  volumes mount root:root and `/home/agent` itself is reset on every sandbox creation)
- startup steps that clear a stale serve lock, run `ai-memory init`, register the ai-memory MCP
  server + hooks (these must re-run per sandbox since `~/.claude*` doesn't survive from the image),
  and background `ai-memory serve` on `127.0.0.1:49374`, polled until it answers before startup
  continues
- a `restore-claude-plugins` step that merges the image's plugin-settings snapshot back into
  `~/.claude/settings.json`. It runs _after_ `install-hooks` so the last writer of that file is not
  the one that could drop the keys, and it is wrapped to always exit 0
- a `jarvis-statusline --install` step, after `restore-claude-plugins` for the same
  last-writer reason, and wrapped to always exit 0
- MySQL reached directly at `host.docker.internal:3306` — the MCP server dials it itself, and the
  base allowlist's `host.docker.internal` rule covers it. An earlier revision tunnelled this through
  the sandbox's HTTP CONNECT proxy with `socat` on `127.0.0.1:3306`; that step and its
  `localhost:3306` allowlist rule are gone.
- conditional registration of the read-only `mysql` MCP server (`ALLOW_INSERT/UPDATE/DELETE/DDL_OPERATION=false`),
  which no-ops with a warning (never a hard failure — a non-zero startup step silently aborts every
  later step) if `MYSQL_USER` or the `claude` CLI isn't available

`scripts/verify-kits.sh` diffs this shared block across every kit found by globbing
`agents/*/spec.yaml`, so a new kit is covered automatically and drift between copies fails CI-style
rather than silently diverging.

### Verification tiers

Three scripts, three different things they can prove:

1. `verify-image.sh` — runs `docker run` against the built image as uid 1000; asserts tool
   presence, correct baked paths, and that every plugin in `config.json` is installed _and_
   enabled (a plugin can be on disk but not loaded, or installed under the wrong uid and
   unreadable — both pass a naive check and fail this one).
2. `verify-kits.sh` — asserts the _resolved_ kit (`sbx kit inspect`), not just spec syntax, since
   `sbx kit validate` reports `VALID` even when `extends` silently resolves to nothing. Also
   asserts the base network allowlist, that no spec declares `MYSQL_*` in `environment.variables`
   (v2 does no host-env interpolation there, so `MYSQL_USER: $MYSQL_USER` arrives as that literal
   string and defeats the startup step's empty-check), and the shared-block drift check.
3. `verify-sandbox.sh` — live checks against a running sandbox (`sbx exec ... `), for the things
   only observable at runtime: whether the MySQL tunnel actually reaches a real MySQL server (not
   just a stub), whether plugin/MCP/`statusLine` state survives the startup steps rewriting
   `~/.claude/settings.json`, whether nested Docker actually comes up.

## Known gaps

- `main.go` invokes `claude --append-system-prompt-file roles/CODER.md` / `roles/REVIEWER.md`, but
  there is no `roles/` directory in this repo — the closest equivalents are
  `agents/coder/files/home/CODER.md` and `agents/reviewer/files/home/REVIEWER.md`. `go run main.go`
  will fail until this is reconciled.
- Read-only kits are prompt-enforced only; see the note under "Kits" above. If the `sbx` spec
  schema grows tool allow/deny support, those five kits should deny `Edit`/`Write`.
