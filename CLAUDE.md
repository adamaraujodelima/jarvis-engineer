# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

`jarvis-engineer` builds a Docker sandbox **template image** for running a Claude Code engineer
agent from one unified kit, `agent/`: an orchestrator persona (`ROLE.md`) plus seven sub-agents —
coder, refactorer, reviewer, expert, investigator, planner, and architect. The kit is that content
plus an `sbx` sandbox spec (`spec.yaml`) that provisions the sandbox: network allowlist, an
`ai-memory` MCP server on a persistent volume, and a read-only MySQL MCP server reached on the host.

The roles, rules and skills are generated from `shared/` (see "Source of truth" below).

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
- `make verify-kits` — static acceptance checks against every `agent*/spec.yaml` (`scripts/verify-kits.sh`)
- `make sync` — regenerate the kit content from `shared/` (`scripts/sync-agents.sh`)
- `make verify-sync` — generator tests, then fail if the committed kit content differs from `shared/`
- `make verify` — `verify-sync`, `verify-image` and `verify-kits`
- `make template` — build + verify-image, then save/load the image into `sbx` as a reusable template
- `make sandbox [KIT=agent] [SANDBOX=jarvis-engineer]` — (re)create a named sandbox from a kit,
  reading MySQL credentials from `.env`, then run `scripts/verify-sandbox.sh` against it
- `make verify-sandbox [SANDBOX=jarvis-engineer]` — live checks against an already-running sandbox
- `make clean` — remove the build tarball

Running the verify scripts directly:

- `./scripts/verify-image.sh [image]` — needs `docker`, `jq`
- `./scripts/verify-kits.sh` — needs the `sbx` CLI (runs `sbx kit validate` / `sbx kit inspect` per kit)
- `./scripts/sync-agents.sh [--check] [--root DIR]` — needs only bash and POSIX tools
- `./scripts/test-sync-agents.sh [filter]` — the generator's acceptance tests, same needs
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

### Kit (`agent/spec.yaml` + `agent/files/home/`)

The kit extends the built-in `claude` sandbox, points `sandbox.image` at
`jarvis-engineer:latest`, and appends the orchestrator persona as the system prompt
(`--append-system-prompt-file /home/agent/ROLE.md`). The seven sub-agents are Claude Code
sub-agents in `files/home/.claude/agents/`, the always-on rules are in `.claude/rules/`, and the
skills in `.claude/skills/`.

Two things about the agent files are worth knowing before editing them:

- `ROLE.md` has no frontmatter: `--append-system-prompt-file` appends it as raw text. The
  frontmatter of `.claude/agents/*.md` is real Claude sub-agent frontmatter (`name`,
  `description`, `model`, `skills`). If you add a `skills:` entry, confirm the skill is actually
  installed by the image.
- Five sub-agents are read-only (`jarvis-reviewer`, `jarvis-investigator`, `jarvis-planner`,
  `jarvis-expert`, `jarvis-architect`) **by prompt only**. The spec grants one unrestricted tool
  set; nothing at the sandbox layer stops those agents from editing files. Treat "read-only" in a
  description as intent, not a guarantee.

The kit also ships `files/home/.jarvis-role` (`ENGINEER`), which is the static role label the
status line renders. It is a file rather than an `environment.variables` entry because
`verify-kits.sh` byte-compares that block across kits, so a per-kit value there reads as drift.
`$JARVIS_ROLE` overrides it; with neither, the line falls back to `AGENT`.

The network allowlist is a base block that every kit must carry plus `registry.npmjs.org` /
`registry.yarnpkg.com` for dependency resolution; `agent/` carries both. `verify-kits.sh` asserts
the base is complete per kit, because the `permissions:` block sits above the shared block and is
invisible to the drift comparison.

The spec carries a block that every kit duplicates verbatim (this is intentional, not an
oversight — `extends` only resolves _built-in_ agents, so pointing it at a local kit for
de-duplication resolves to an empty parent while `sbx kit validate` still reports `VALID`):

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
`agent*/spec.yaml`, so a new kit is covered automatically and drift between copies fails CI-style
rather than silently diverging. With `agent/` the only Claude kit, that comparison is vacuous for now.

### Source of truth (`shared/`)

`shared/` is the hand-edited source for the kit's content; `scripts/sync-agents.sh` generates
`agent/files/home/{ROLE.md,.claude/agents,.claude/rules,.claude/skills}` from it. Those four paths
are generated and committed — never hand-edit them. Edit `shared/`, run `make sync`, and commit
both. CI runs `sync-agents.sh --check`, which regenerates into a temp dir and fails on any
extra, missing or changed file in the owned paths. Everything else in the kit (`spec.yaml`,
`.jarvis-role`, `.claude/settings.json`, `.claude/workflows/`) is hand-owned and never touched.

- `shared/role/ROLE.md` (target-neutral core) + `shared/role/delegation.claude.md` are
  concatenated, with one blank line between them, into `ROLE.md`.
- `shared/agents/<role>.md` → `.claude/agents/<role>.md`. Frontmatter is a flat subset only
  (`key: value`, no nesting, no block scalars) with an allowlist: `name`, `description` (required),
  `rules` (bare rule names; dropped for Claude, which loads every rule), `claude.model`,
  `claude.skills` (emitted as `model:` / `skills:`). Anything else is rejected. Neutral sources
  (`agents/*.md`, `role/ROLE.md`) must not mention `.claude/` or `subagent_type`.
- `shared/rules/*.md` → `.claude/rules/`; a leading frontmatter block (e.g. `golang-idioms.md`'s
  `paths:`) is passed through untouched.
- `shared/skills/<name>/` → `.claude/skills/<name>/`, byte for byte; `SKILL.md` may use only
  `name` and `description`.
- Each generated file except the skills carries a `<!-- GENERATED by scripts/sync-agents.sh ... -->`
  marker, after the frontmatter when there is one, otherwise on line 1. Bodies are copied
  byte-exact; several sources end without a newline and must stay that way.

Both scripts must run on macOS bash 3.2 and BSD tools as well as Linux: no `mapfile`, associative
arrays or `${v,,}`; POSIX awk only (no gawk extensions, no `{n}` intervals, no `\s`); no `sed -i`,
no `readlink -f`, no GNU `diff` format flags; `mktemp -d "${TMPDIR:-/tmp}/name.XXXXXX"`.

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
   string and defeats the startup step's empty-check), the shared-block drift check, and that the
   generated kit content matches `shared/` (`sync-agents.sh --check`).
3. `verify-sandbox.sh` — live checks against a running sandbox (`sbx exec ... `), for the things
   only observable at runtime: whether the MySQL tunnel actually reaches a real MySQL server (not
   just a stub), whether plugin/MCP/`statusLine` state survives the startup steps rewriting
   `~/.claude/settings.json`, whether nested Docker actually comes up.

## Known gaps

- `main.go` invokes `claude --append-system-prompt-file roles/CODER.md` / `roles/REVIEWER.md`, but
  there is no `roles/` directory in this repo — the closest equivalents are now
  `shared/agents/coder.md` and `shared/agents/reviewer.md`. `go run main.go` will fail until this
  is reconciled.
- The five read-only sub-agents are prompt-enforced only; see the note under "Kit" above. If the
  `sbx` spec schema grows tool allow/deny support, they should be denied `Edit`/`Write`.
