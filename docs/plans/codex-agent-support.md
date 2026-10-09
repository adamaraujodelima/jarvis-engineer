# Plan: centralize agent content under `shared/`, then add a Codex kit

Status: Phase 1 DONE (2026-10-09; Step 1.11 gate green except the host-MySQL greeting, see there; branch
protection change still open). Phase 2 DONE (2026-10-09) except S9's inherited
allowlist, which is not a gate: content-path direct, AGENTS.md budget 16 KiB, no agent cap, read-only not enforced,
hook-mode pretrust, mysql forward via `env_vars`, model `gpt-5.6-terra`. Phase 3 is unblocked except for Step 3.1 (the user's rule bindings).
Authority: `docs/architecture/agent-centralization.md` (the ADR). This file replaces the earlier draft
(coder-only pilot, `agents-codex/`), which the ADR superseded. Facts from that draft that still
hold (Codex config, ai-memory 2.0.1 behavior, base image names) are carried into Phase 3 below.

This plan was written in a sandbox without `sbx`. Where a step has a "Result" note or a filled spike row, that
result was observed on the host. Everything else is still unverified.

## 0. Decisions and working rules

User decisions (final, 2026-10-08):

| # | Decision | Effect on this plan |
|---|----------|---------------------|
| U1 | Legacy single-role `agents/*/` kits are retired | Step 1.9 deletes them. `verify-kits.sh`, `.dockerignore`, `CLAUDE.md` and two spec comments stop referring to them. |
| U2 | Where roles drifted, `agent/` wins | `shared/` is seeded from `agent/`. Step 1.1 lists what only the legacy copies contain, before deletion. |
| U3 | Hook trust: bypass flag only if the spike shows Claude-kit parity; keep the ADR's preferred pre-trust of ai-memory hooks if Codex stores trust | Phase 2 S7 decides. See the decision order in section 4. |

Interpretation to confirm (does not block Phase 1): U3 lists two options that can both be true. This
plan resolves it as: stored Codex trust available -> pre-trust only ai-memory's hooks; else Claude
parity shown -> bypass flag; else MCP-only memory. That matches ADR D6 ("prefer pre-trust").

Working rules for whoever implements:

- Stage explicit paths only (`git add <paths>`). Never `git add -A`. The repo root has untracked
  `.bashrc`, `.bash_profile`, `.gitconfig`, `.gitmodules`, `.profile`, `.ripgreprc`, `.vscode`,
  `.zprofile`, `.zshrc`, `.idea/`, `.claude/`. They are not part of this work.
- TDD: each step that changes behavior starts with its acceptance check failing (capture the red
  output for the PR description), then goes green. Commit RED+GREEN together so every commit passes CI.
- Script portability (the user's host is macOS, inferred from the repo path, and CI is Ubuntu; the
  planning sandbox has bash 5.3 and mawk): bash 3.2 compatible (no `mapfile`, associative arrays,
  `${v,,}`), POSIX awk only (no gawk extensions, no `{n}` regex intervals, no `\s`), no `sed -i`, no
  `readlink -f`, no GNU `diff` format flags, `mktemp -d "${TMPDIR:-/tmp}/name.XXXXXX"` form. The
  existing scripts already avoid `mapfile` for this reason.
- Commit subjects follow Conventional Commits (`feat(sync): ...`, `test(sync): ...`, `refactor(kits): ...`).

## 1. Existing implementation (verified by reading the repo)

- `agent/` is the unified kit and the Makefile default (`KIT ?= agent`). Content: `ROLE.md` (6.0 KB),
  `.claude/agents/*.md` (7 roles), `.claude/rules/*.md` (5), `.claude/skills/*/SKILL.md` (4),
  `.claude/settings.json`, `.claude/workflows/implement-review-loop.js`, `.jarvis-role` (`ENGINEER`),
  `spec.yaml` (9 startup steps, name `jarvis-engineer`).
- `scripts/verify-kits.sh` discovers `agents/*/spec.yaml` only. `agent/` has no kit-level check. It
  cannot simply be added to the glob: the role-label check derives the expected label from the
  directory name (`basename | upper` = `AGENT`), while `agent/files/home/.jarvis-role` says `ENGINEER`.
  Every other per-kit case I traced (`jarvis-engineer:latest`, `9 startup`, allowlist, mysql flags,
  `CLAUDE=` path, readiness text, serve line, chown, `AI_MEMORY_DATA_DIR`) is satisfied by
  `agent/spec.yaml` as written.
- `agents/` holds 30 tracked files (7 specs, 7 `.jarvis-role`, 6 role personas, coder rules and
  `CODER.md`/`CODE_STYLE.md`/`GOLANG_IDIOMS.md`, `REVIEWER.md`, `TEMPLATE.md`, 2 reviewer skills).
  Measured against `agent/`: `testing.md`, `conventional-commit.md`, `golang-idioms.md` (body), and the
  reviewer's two skills are identical; `code-style.md` differs only by a legacy "Language-specific
  guides" section (legacy lines 183-192, points at `/home/agent/GOLANG_IDIOMS.md`); personas differ
  in 3 to 61 lines per role; `REVIEWER.md` (6.7 KB, `/security-review` every round, skill routing,
  output via `TEMPLATE.md`) has a different structure from `reviewer.md` (1.5 KB) + `rules/code-review.md`.
- Byte facts the generator must respect. Six source files have no trailing newline: `ROLE.md`,
  `agents/planner.md`, `rules/code-review.md`, `rules/golang-idioms.md`, and the two postgresql
  `SKILL.md`. Output must stay byte-exact, so bodies are emitted with `tail -n +N`/`cat`/`cp`, never a
  `while read` / `awk print` loop (those append a newline).
- Frontmatter facts. Six agent files are flat (`name`, `description`, plus `skills: ["superpowers:systematic-debugging"]`
  on the investigator and `model: sonnet` on the planner). `reviewer.md` closes with a 110-dash run.
  Rules have no frontmatter except `golang-idioms.md`, which has a nested `paths:\n  - "**/*.go"`
  (Claude path scoping). The ADR does not cover this; see Risks R5. Skills are flat (`name`, `description`).
- `ROLE.md`: no frontmatter; line 4 is its only `.claude/` reference; it names agents without the
  `jarvis-` prefix (`investigator`, `coder`, ...) in backticks in "Sub-agent roles" and "Iterative
  workflow", while the agents are named `jarvis-*`.
- `agent/spec.yaml` has two stale comments about legacy kits: line 37 ("every agents/*/spec.yaml") and
  line 151 (`--kit agents/coder jarvis-coder`). Comments are stripped by the drift comparison, so editing
  them is safe.
- CI (`.github/workflows/ci.yml`): jobs `go` and `image`. `dependabot-auto-merge.yml` says branch
  protection requires `go` and `image`. `.dockerignore` excludes `agents` and `scripts` (except the three
  installed scripts); nothing in the Dockerfile copies kit content.
- `docs/` is untracked, so the ADR and this plan are not in git yet.

## 2. Objective and approach

Objective: one hand-edited source (`shared/`) for roles, rules and skills; generated, committed kit
content with a CI drift gate; retire the legacy kits; then add a Codex kit on top, as the ADR decides.

Approach: the ADR's design unchanged (D1 to D7). Phase 1 delivers the Claude half. Phase 3 adds a
Codex output target to the same generator. No decision of the ADR is reopened.

## 3. Phase 1: centralize and generate (no spike needed)

Generator interface (defined once, used by tests and Makefile): `scripts/sync-agents.sh [--check] [--root DIR]`.
`--root` (default: repo root) is the directory holding `shared/` and the kit directories; tests point it
at a fixture. Exit codes: 0 ok, 1 drift (`--check`), 2 invalid source or usage. Diagnostics go to stderr
and name the file and the offending key or line.

Claude target, owned subtrees of `agent/files/home` (everything else in the kit is hand-owned and never
read or written): `ROLE.md`, `.claude/agents/`, `.claude/rules/`, `.claude/skills/`.

### Step 1.0 Record the decisions

- Files: `docs/architecture/agent-centralization.md` (status line, D5, D6), `docs/plans/codex-agent-support.md`.
- Change: set the ADR status to ACCEPTED; record U1 (retire), U2 (agent/ wins), U3 and the order in
  section 4 under D5/D6. Commit `docs/` (explicit paths).
- Accept: `git ls-files docs` lists both files. Run: `git ls-files docs`.

### Step 1.1 List the legacy-only content (read-only, before anything is deleted)

Output goes to the final report to the user and into the body of the retirement commit (1.9). Nothing is
merged into `shared/`.

- Files: none changed. Scratch output under `$TMPDIR/legacy-only/` (not in the repo).
- Change: classify every one of the 30 tracked files under `agents/` as IDENTICAL (name the `agent/`
  counterpart, proven with `cmp`), DIFFERS (attach `diff -u` against the `agent/` counterpart, with the
  frontmatter ignored), or LEGACY-ONLY. Then write a plain-language list of the content that exists only
  in the legacy copies. Known items to confirm and describe:
  1. `REVIEWER.md` against `reviewer.md` + `code-review.md`: for each section of `REVIEWER.md`
     (`grep -n '^#'`) say whether the unified kit has an equivalent. At minimum: mandatory
     `/security-review` at the start of every round, the skill-routing rules, the read-only and
     temp-artifact cleanup rule, the "Once you have answered something..." paragraph, and the output
     contract that points at `TEMPLATE.md`.
  2. `TEMPLATE.md` (362 B finding layout): legacy-only. The unified `code-review.md` has its own
     "Finding Format".
  3. `code-style.md` "Language-specific guides" section (legacy lines 183-192). In `agent/` the Go
     guide is `rules/golang-idioms.md`, loaded for `**/*.go`, so the pointer has no target there.
  4. Persona drift for architect, expert, investigator, planner, refactorer, coder: attach the
     legacy-side lines (the `<` side of `diff legacy agent`; measured counts: 6, 61, 42, 15, 38, 1).
  5. Per-role network least privilege: legacy read-only kits have no `registry.npmjs.org` /
     `registry.yarnpkg.com`; `agent/spec.yaml` grants them to the whole kit.
  6. Per-role `displayName`/`description` in legacy specs (confirm the descriptions equal the `agent/`
     agent frontmatter) and per-role `.jarvis-role` labels.
  7. The capability itself: single-role sandboxes (`--kit agents/coder`).
- Accept: the classification table has 30 rows and no unclassified file:
  `git ls-files agents | wc -l` equals the row count.
- Run: `cmp`/`diff -u` per pair; the table is the evidence.

### Step 1.2 RED: acceptance tests for the generator

- Files: `scripts/test-sync-agents.sh` (new).
- Change: same `check`/pass/fail style as `verify-*.sh`. Builds a fixture in `mktemp -d` per case
  (`shared/` with one neutral role core, one `delegation.claude.md`, two agents, two rules (one with nested
  frontmatter), one skill; and `agent/files/home` with hand-owned `spec.yaml`, `.jarvis-role`,
  `.claude/settings.json`, `.claude/workflows/x.js`). Invokes the generator as `"$BASH" scripts/sync-agents.sh --root <fixture>`
  so the interpreter under test is the one running the suite (lets CI run it under `/bin/bash` 3.2 on macOS).
  Accepts an optional substring filter to run one group. Asserts exit class and that the diagnostic names
  the file; it does not assert full message text.
- Cases (name = behavior):

| Group | Case |
|-------|------|
| emit | writes `name`/`description` unchanged and maps `claude.model` to `model:` |
| emit | passes list values through byte for byte (`claude.skills: ["a:b"]` -> `skills: ["a:b"]`) |
| emit | drops the `rules:` key: no `rules:` line appears in Claude agent files |
| emit | places the generated marker after the closing fence, and before line 1 for files with no frontmatter |
| emit | keeps a source body without a trailing newline without one (the planner/ROLE case) |
| emit | keeps a rule's nested frontmatter first and puts the marker after it |
| emit | copies skill directories byte for byte, with no marker |
| emit | concatenates role core, one blank line, `delegation.claude.md` into `ROLE.md` |
| reject | unknown frontmatter key (e.g. `color: red`) |
| reject | nested or multi-line frontmatter (indented line, block scalar `|`/`>`) in an agent |
| reject | frontmatter closed by anything but `---` (the reviewer.md dash run), in an agent or a rule |
| reject | missing `name` or `description`; duplicate key; empty value |
| reject | `rules:` entry with no `shared/rules/<name>.md` |
| reject | `.claude/` or `subagent_type` in `shared/agents/*.md` or `shared/role/ROLE.md` |
| reject | skill with a key outside `name`, `description` |
| reject | invalid source leaves the kit directory unchanged (checksum before/after) |
| sync | second run changes nothing; a removed source removes its generated file; hand-owned paths untouched |
| check | passes on a freshly generated kit |
| check | fails and names the file when a generated file is hand-edited |
| check | fails on an extra and on a missing file inside an owned subtree |
| check | passes when only hand-owned files (`spec.yaml`, `.jarvis-role`, `settings.json`, `workflows/`) differ |
| check | does not modify the kit and leaves no temp directory behind |
| determinism | identical output under `LC_ALL=C` and `LC_ALL=en_US.UTF-8` |

- Accept (RED): `./scripts/test-sync-agents.sh` exits non-zero with every case failing because
  `scripts/sync-agents.sh` does not exist. Run: `./scripts/test-sync-agents.sh; echo $?`.

### Step 1.3 GREEN: generator, Claude agents and validation

- Files: `scripts/sync-agents.sh` (new; `#!/usr/bin/env bash`, `set -uo pipefail`, same header-comment style).
- Change: implement `--root`, temp dir with `trap` cleanup, and the agent pipeline.
  - Frontmatter: line 1 must be `---`; the closing fence is the first line of 3+ dashes and must equal
    `---` exactly. Every line must match `key: value` with a non-empty value (no continuation, no `|`/`>` block
    scalar). Key allowlist (one variable, widened deliberately): `name description rules claude.model claude.skills`.
    `name` and `description` required, no duplicates. Values are opaque raw text, never re-quoted.
  - `rules: [a, b]`: bare names, each must exist as `shared/rules/<name>.md`. No agent declares
    `rules:` in Phase 1 (Claude drops it and has no consumer); Phase 3 adds them.
  - Neutral-source lint: `grep -F` for `.claude/` and `subagent_type` in `shared/agents/*.md` and `shared/role/ROLE.md`.
  - Emit: `---`, then each kept key in source order (`claude.X` as `X:`; `rules` dropped), `---`, the marker
    line, then the body via `tail -n +<closing+1>`. Marker text is one constant:
    `<!-- GENERATED by scripts/sync-agents.sh from shared/<path> -- edit that file, not this one -->`.
  - Generate everything into a temp tree first; touch the kit only after the whole tree built and validated.
- Accept: groups `emit` (agents) and `reject` (agent/rule frontmatter, rules, lint) go green.
- Run: `./scripts/test-sync-agents.sh emit; ./scripts/test-sync-agents.sh reject`.

### Step 1.4 GREEN: rules, skills, ROLE.md

- Files: `scripts/sync-agents.sh`.
- Change: rules: marker (after frontmatter if line 1 is `---`, else first line) then `cat`; fence rule as above
  but nested content between the fences is passed through untouched. Skills: key check (`name`, `description`
  only; widen on demand) and `cp -R` of the directory. ROLE: marker, core, one blank line, `delegation.claude.md`;
  both sources must end with a newline (reject otherwise).
- Accept: remaining `emit` cases green.
- Run: `./scripts/test-sync-agents.sh emit`.

### Step 1.5 GREEN: sync and `--check`

- Files: `scripts/sync-agents.sh`.
- Change: sync replaces each owned path wholesale (build in temp, then `rm -rf` target and `cp -R`). `--check` builds
  the same temp tree and compares each owned path with `diff -r`, printing `drift: <path>` per difference and
  `run: make sync` as the hint. Never writes in `--check`.
- Accept: groups `sync`, `check`, `determinism` green; full suite green.
- Run: `./scripts/test-sync-agents.sh` (exit 0, 0 failed).

### Step 1.6 Seed `shared/` from `agent/`

- Files: `shared/role/ROLE.md`, `shared/role/delegation.claude.md`, `shared/agents/{architect,coder,expert,investigator,planner,refactorer,reviewer}.md`,
  `shared/rules/{code-review,code-style,conventional-commit,golang-idioms,testing}.md`, `shared/skills/{postgresql-code-review,postgresql-optimization,sql-code-review,sql-optimization}/SKILL.md`.
- Change:
  - Rules and skills: copy from `agent/files/home/.claude/` unchanged.
  - Agents: copy; inside the frontmatter only, rename `model:` -> `claude.model:` (planner) and `skills:` ->
    `claude.skills:` (investigator); in `reviewer.md` replace the dash-run line with `---`.
  - `ROLE.md` core: current text with exactly these edits: line 4 loses "defined in `.claude/agents`" (reads "...specialized
    sub-agents. Use them when..."); backticked agent names in "Sub-agent roles" and "Iterative workflow" become
    `jarvis-<role>`; file ends with a newline. `delegation.claude.md`: a short `## Delegation mechanics (Claude Code)`
    section that states only the relocated fact (the sub-agents are defined in `.claude/agents`, read the definition before delegating).
- Accept: `./scripts/sync-agents.sh --check` reports drift for exactly the files listed in 1.7 (expected before regeneration).
- Note: the ADR (section 6) says the Claude fragment also covers the Agent tool and the `implement-review-loop`
  workflow. The current `ROLE.md` mentions neither. Adding them is new orchestrator prompt content, so this
  plan relocates only existing text. Say if you want the larger fragment.

### Step 1.7 Regenerate `agent/` and prove only the intended changes

- Files: `agent/files/home/ROLE.md`, `agent/files/home/.claude/agents/*.md`, `agent/files/home/.claude/rules/*.md`.
- Change: `./scripts/sync-agents.sh`.
- Accept (golden master against the committed tree), with `BASE=$(mktemp -d "${TMPDIR:-/tmp}/base.XXXXXX"); git archive HEAD agent | tar -x -C "$BASE"` taken before regenerating:
  1. Changed set is exactly: `ROLE.md`, the 7 agent files, the 5 rule files (`git diff --name-only -- agent`).
  2. Intended differences only:
     - I1: one marker line in each of those 13 files (none in skills).
     - I2: `reviewer.md` closing fence is `---`.
     - I3: `ROLE.md` line-4 edit, the appended delegation section, a trailing newline.
     - I4: `ROLE.md` backticked agent names carry the `jarvis-` prefix.
  3. For the 11 files not listed under I2-I4: `diff <(grep -v '^<!-- GENERATED by' new) base` is empty.
     That covers `planner.md`, `code-review.md` and `golang-idioms.md`, so the missing-trailing-newline case is proven on real files.
  4. Hand-owned and skill paths unchanged: `git diff --quiet -- agent/spec.yaml agent/files/home/.jarvis-role agent/files/home/.claude/settings.json agent/files/home/.claude/workflows agent/files/home/.claude/skills`.
  5. `./scripts/sync-agents.sh --check` exits 0.
- Run: the commands above; paste the `ROLE.md` diff into the commit body.

### Step 1.8 RED then GREEN: `verify-kits.sh` covers `agent/`

- Files: `scripts/verify-kits.sh`, `agent/spec.yaml` (comments only).
- Change:
  - RED first: change discovery to `for spec in agent*/spec.yaml` (matches `agent/` now and `agent-codex/` later,
    not the legacy layout, which is `agents/<role>/spec.yaml`). Run with the shim below: the role-label case fails
    (`want AGENT`, got `ENGINEER`). Capture it.
  - GREEN: replace `basename | upper` with a `role_label()` function (`case`: `agent` -> `ENGINEER`; any
    other directory keeps the old derivation). Add one case before the loop: `scripts/sync-agents.sh --check` passes
    ("generated kit content matches shared/"). Add a comment that the shared-block drift loop is vacuous
    with one kit per family and that the cross-family invariants arrive in Phase 3. Fix the two stale
    comments in `agent/spec.yaml` (line 37 -> "Duplicated in the Claude and Codex kits"; line 151 -> `--kit agent jarvis-engineer`).
  - `BASE_ALLOW` still contains `code.claude.com`; Phase 3 splits it per family.
- Accept: every per-kit case passes for `agent`. Real `sbx` output is not available here: use an uncommitted shim at
  `$TMPDIR/shim/sbx` (`kit validate <dir>` prints `VALID`; `kit inspect <dir>` prints the spec's `sandbox.image`
  and `<n> startup steps` counted from the spec) and run `PATH=$TMPDIR/shim:$PATH ./scripts/verify-kits.sh`. This proves
  the script logic only; it proves nothing about real `sbx` output.
- Run (host, before merge): `make verify-kits` with real `sbx`. This is a required user action.

### Step 1.9 Retire the legacy kits

- Files: delete `agents/` (30 files); edit `.dockerignore` (drop the `agents` line), `CLAUDE.md`.
- Change: `git rm -r agents`. Commit body: the 1.1 legacy-only summary and the SHA of the last commit that
  contains `agents/` (`git rev-parse HEAD` just before the deletion; `2fc9e46` at planning time) so
  `git show <sha>:agents/reviewer/files/home/REVIEWER.md` recovers anything.
  `CLAUDE.md` edits, by section:
  - Intro and "Kits": one unified kit `agent/` (orchestrator `ROLE.md` plus seven sub-agents), not seven
    single-role kits; remove "All seven kits"/"All seven specs"; the persona-frontmatter note now applies only to
    `.claude/agents/*.md`, whose frontmatter is real Claude sub-agent frontmatter (`ROLE.md` has none).
  - Commands: `make verify-kits` covers `agent*/spec.yaml`; `make sandbox [KIT=agent] [SANDBOX=jarvis-engineer]`;
    add `make sync` and `make verify-sync` (wired in 1.10).
  - Network allowlist paragraph: the base-plus-registry split no longer describes separate kits; `agent/` carries both.
  - Read-only roles: now "five sub-agents are read-only by prompt only"; the gap is unchanged.
  - Known gaps: `main.go` still points at `roles/`; the nearest sources are now `shared/agents/coder.md` and
    `shared/agents/reviewer.md`. `main.go` itself is not touched (ADR section 11).
  - New section "Source of truth": `shared/` is edited, `agent/files/home/{ROLE.md,.claude/agents,.claude/rules,.claude/skills}`
    is generated and committed, never hand-edited; `make sync`; CI runs `--check`; flat-frontmatter rules; the portability constraints from section 0.
- Accept: `grep -rn 'agents/' CLAUDE.md Makefile scripts .github .dockerignore agent/spec.yaml` has no hit that refers to the legacy layout
  (`.claude/agents`, `shared/agents` are fine). `agents/` is gone: `test ! -e agents`.
- Run: the grep above; `PATH=$TMPDIR/shim:$PATH ./scripts/verify-kits.sh`; `./scripts/sync-agents.sh --check`.

### Step 1.10 Makefile and CI

- Files: `Makefile`, `.github/workflows/ci.yml`.
- Change: Makefile adds `sync` (`./scripts/sync-agents.sh`) and `verify-sync` (`./scripts/test-sync-agents.sh` then
  `./scripts/sync-agents.sh --check`), both in `.PHONY` with `##` doc comments, and `verify: verify-sync verify-image verify-kits`.
  CI adds job `sync` with matrix `os: [ubuntu-latest, macos-latest]`, same pinned `actions/checkout` as the other jobs,
  steps `make verify-sync`; on macOS an extra step runs `/bin/bash scripts/test-sync-agents.sh` so bash 3.2 is exercised
  (the test script passes its own `$BASH` to the generator). Update the comment at the top of the `image` job so it lists what runs where.
  The macOS leg is recommended, not required by the ADR; drop it if runner cost matters.
- Accept: RED first: `make verify-sync` fails when a generated file is hand-edited and passes after `make sync`.
- Run: `make verify-sync`; then locally `echo x >> agent/files/home/.claude/rules/testing.md; make verify-sync` (must fail, naming the file), `git checkout -- agent`.
- User action: add `sync` (both matrix legs) to the required checks in branch protection. The comment in
  `dependabot-auto-merge.yml` lists the required checks as `go` and `image`; update it once that is done.

### Step 1.11 Phase 1 regression gate

- Run: `./scripts/test-sync-agents.sh`; `./scripts/sync-agents.sh --check`; `go build ./... && go vet ./...`;
  `make build && make verify-image` (host or CI; the image does not read kit content, so no change is expected).
- Host-only, required before merge: `make verify-kits`; `make sandbox` then
  `sbx exec jarvis-engineer -- sh -c 'ls ~/.claude/agents ~/.claude/rules; head -2 ~/ROLE.md'` and open Claude's agent list to confirm all 7 agents
  parse (the reviewer now has a valid fence) and the orchestrator reads `jarvis-*` names. If the marker line changes agent behavior
  in any observable way, the marker is one constant in the script and can be removed; `--check` still guards edits.
- Result (2026-10-09, macOS host, sbx v0.47.0, Claude Code 2.1.280):
  - `test-sync-agents.sh` 44/44, `sync-agents.sh --check` clean, `go build`/`go vet` clean.
  - `make verify-image` 35/35, `make verify-kits` 21/21.
  - Live tier ran as `make sandbox SANDBOX=jarvis-p1-check` (a throwaway name, so the existing `jarvis-engineer`
    sandbox was not removed): 16/17. The one failure is "the port answers as a real MySQL server": nothing listened on
    host port 3306 at the time, and the sandbox side accepted the TCP connection and then closed it with no bytes.
    That is the environment, not this change. Re-run `make verify-sandbox` with MySQL up before merge.
  - All 7 `jarvis-*` agents are listed by Claude in the sandbox, `~/.claude/rules` holds the 5 rules, and `~/ROLE.md`
    starts with the marker then `# Role`. `claude agents --json` lists background sessions, not sub-agent definitions,
    so the agent list was taken from a `claude -p` run instead.

## 4. Phase 2: spike S1 to S10 (the user runs these on the host)

Rules: run in this order; record results in the table at the end of this section and commit it to this file.
Everything is under `~/spike` and two throwaway sandboxes, so no repo file changes. Several answers come from Codex
describing its own context (S4, S5); corroborate by listing files or logs where possible.
Commands are believed correct; flags I could not check (`codex exec`, `codex features`, `-c key=value`) are
confirmed first with `--help`. `sbx` and Codex behavior below are unverified.

Preconditions (host): `sbx --version`; `docker info`; `sbx secret set openai` (or `--oauth`) done; `make template` done (S7c uses `jarvis-engineer:latest`).

### S0 Scaffold (no sandbox yet)

```
! mkdir -p ~/spike/codex-spike/files/home/{.codex/agents,.codex/rules,.agents/skills/spike-ok,.agents/skills/spike-extra} ~/spike/work ~/spike/claude-work/.claude
! printf 'schemaVersion: "2"\nkind: sandbox\nname: codex-spike\nextends: codex\ndisplayName: Codex spike\ndescription: "Throwaway spike kit"\n' > ~/spike/codex-spike/spec.yaml
! { echo 'SPIKE-GLOBAL-LINE-1'; for i in $(seq -w 1 20); do printf 'G-%s %s\n' "$i" "$(head -c 1000 /dev/zero | tr '\0' x)"; done; } > ~/spike/codex-spike/files/home/.codex/AGENTS.md
! { for i in $(seq -w 1 20); do printf 'P-%s %s\n' "$i" "$(head -c 1000 /dev/zero | tr '\0' x)"; done; } > ~/spike/work/AGENTS.md
! printf 'name = "jarvis-spike"\ndescription = "Spike agent that replies SPIKE-AGENT-OK and writes files when asked."\ndeveloper_instructions = """\nYou are jarvis-spike. Reply with exactly SPIKE-AGENT-OK unless asked to write a file; if asked, write it.\n"""\n' > ~/spike/codex-spike/files/home/.codex/agents/jarvis-spike.toml
! printf 'name = "jarvis-ro"\ndescription = "Spike agent with a read-only sandbox."\nsandbox_mode = "read-only"\ndeveloper_instructions = """\nYou are jarvis-ro. If asked to write a file, attempt it and report the exact outcome.\n"""\n' > ~/spike/codex-spike/files/home/.codex/agents/jarvis-ro.toml
! { printf 'name = "jarvis-big"\ndescription = "Spike agent with a 32 KiB prompt."\ndeveloper_instructions = """\n'; for i in $(seq -w 1 32); do printf 'B-%s %s\n' "$i" "$(head -c 1000 /dev/zero | tr '\0' x)"; done; printf '"""\n'; } > ~/spike/codex-spike/files/home/.codex/agents/jarvis-big.toml
! printf -- '---\nname: spike-ok\ndescription: Spike skill. Use when asked for the spike skill word. Answer SPIKE-SKILL-OK.\n---\n\nAnswer SPIKE-SKILL-OK.\n' > ~/spike/codex-spike/files/home/.agents/skills/spike-ok/SKILL.md
! printf -- '---\nname: spike-extra\ndescription: Spike skill carrying Claude-only keys.\nmodel: sonnet\npaths: ["**/*.go"]\n---\n\nAnswer SPIKE-EXTRA-OK.\n' > ~/spike/codex-spike/files/home/.agents/skills/spike-extra/SKILL.md
! printf 'RULES-PROBE\n' > ~/spike/codex-spike/files/home/.codex/rules/probe.md
! git -C ~/spike/work init -q
```

I ran these in a temp directory: they produce a 20,140-byte global `AGENTS.md`, a 20,120-byte project `AGENTS.md`, a 32,295-byte `jarvis-big.toml`.

Hook fixtures (S7). They derive the hooks schema from ai-memory's own output, then swap the commands for a harmless log write:

```
! docker run --rm --entrypoint sh jarvis-engineer:latest -c 'export HOME=$(mktemp -d); AI_MEMORY_DATA_DIR=$HOME/m ai-memory init >/dev/null 2>&1; ai-memory install-hooks --agent codex --apply >/dev/null 2>&1; cat $HOME/.codex/hooks.json' > ~/spike/hooks.ai-memory.json
! jq '(.. | select(type=="object" and has("command")) | .command) |= "sh -c \"date >> /home/agent/hook-global.log\""' ~/spike/hooks.ai-memory.json > ~/spike/codex-spike/files/home/.codex/hooks.json
! mkdir -p ~/spike/work/.codex && jq '(.. | select(type=="object" and has("command")) | .command) |= "sh -c \"date >> /home/agent/hook-project.log\""' ~/spike/hooks.ai-memory.json > ~/spike/work/.codex/hooks.json
! grep -c 'hook-global' ~/spike/codex-spike/files/home/.codex/hooks.json; grep -c 'hook-project' ~/spike/work/.codex/hooks.json
```

Both counts must be at least 1. A 0 means the hooks file uses a key other than `command`; record the file and adapt before continuing.
Claude parity fixture (S7c): `! printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch .hook-fired"}]}]}}\n' > ~/spike/claude-work/.claude/settings.json`

### Spike items

| # | Run (host, `!`) | Record | Outcome -> action |
|---|-----------------|--------|-------------------|
| S9 | `! sbx kit inspect codex > ~/spike/s9-codex.txt; sbx kit inspect ~/spike/codex-spike >> ~/spike/s9-codex.txt` (run before create) | Inherited `command`, network allowlist, credentials, volumes, image | Pin both flags explicitly in the kit `command` regardless. Copy the inherited allowlist hosts into the Phase 3 spec. |
| S2 | `! sbx create --name codex-spike --kit ~/spike/codex-spike codex-spike ~/spike/work` then, before ever starting Codex: `! sbx exec codex-spike -- sh -c 'pwd; ls -la ~/.codex; cat ~/.codex/config.toml 2>&1 \| head -40'` | Does `~/.codex/config.toml` exist after create, its content and mtime | Either way the kit ships no `config.toml`; startup steps write all config. |
| S1 | `! sbx exec codex-spike -- sh -c 'ls -R ~/.codex ~/.agents \| head -40; head -1 ~/.codex/AGENTS.md'`; then `! sbx exec codex-spike -- sh -c 'codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "Do not use tools. Quote the first line of your global AGENTS.md verbatim. List the custom agents and the skills available to you."'` | Files present? Quoted line equals `SPIKE-GLOBAL-LINE-1`? Agents and skills listed? (If `pwd` above is not the workspace holding `AGENTS.md`, `cd` there first.) | All present and loaded -> generate straight into `files/home/.codex`, `.agents/skills`. Missing or not loaded -> Phase 3 uses `files/home/.jarvis/codex/**` plus a copy startup step (ADR S1 fallback). |
| S3 | Same run as S1; also `... 2>&1 \| grep -iE 'skill\|warn\|invalid'` | Is `spike-extra` (Claude-only keys) listed, rejected, or warned about | Informational. The source already allows only `name`/`description`. |
| S4 | `! sbx exec codex-spike -- sh -c 'codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "Do not use tools. Report the highest marker of the form G-NN and the highest of the form P-NN present anywhere in the instructions you were given (NONE if absent). Then say whether a file named probe.md in ~/.codex/rules caused any warning."'` and `! sbx exec codex-spike -- sh -c 'codex execpolicy --help 2>&1 \| head -20; ls -la ~/.codex/rules'` | Highest G and P markers (global 20 KiB + project 20 KiB: a combined 32 KiB cap shows as P cut near P-12; a separate cap shows P-20); what `~/.codex/rules` is for | Set the generator's `AGENTS.md` budget from the measured numbers (ADR default 16 KiB). Keep rule files under `~/.jarvis/rules` either way. |
| S5 | `! sbx exec codex-spike -- sh -c 'codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "Use the jarvis-spike agent and report its reply. Then use the jarvis-big agent and report the highest marker B-NN in its instructions."'` | Agents discovered and invokable by hyphenated name? Highest B marker (32 = no cap at 32 KB). If not discovered, the documented agent directory and file format | Invokable, no cap -> inline rules as designed. Capped -> ADR S5 fallback (role body inline, long rules read on demand via the index). Not discovered -> stop Phase 3 and return to the architect: the agent directory differs from the ADR. |
| S6 | `! sbx exec codex-spike -- sh -c 'codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "Ask jarvis-ro to write the text hi to /home/agent/ro-probe.txt, and ask jarvis-spike to write hi to /home/agent/rw-probe.txt. Report both outcomes."'` then `! sbx exec codex-spike -- sh -c 'ls -la /home/agent/*-probe.txt'` | Judge by the filesystem, not the model's report. `rw-probe.txt` is the control (must exist, else the test proves nothing) | `ro-probe.txt` absent and control present -> enforced: allow `codex.sandbox_mode` and set `read-only` on investigator, architect, planner, expert, reviewer. Present -> prompt-only (I7), no `codex.sandbox_mode` key allowed. |
| S7a | `! sbx exec codex-spike -- sh -c 'codex features list 2>&1 \| grep -i hook'; sbx exec codex-spike -- sh -c 'codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "say hi"; ls -la /home/agent/hook-*.log'` | `features.hooks` default; whether global (`hook-global.log`) and project (`hook-project.log`) hooks fired without the bypass flag. If neither fired, retry with `-c features.hooks=true` and record which was needed | Startup step must set `features.hooks` if it was needed. |
| S7b | Repeat S7a with `codex --dangerously-bypass-hook-trust exec ...` (or whatever `codex exec --help` shows). Then interactive: `! sbx run codex-spike`, accept the hook review, exit; then `! sbx exec codex-spike -- sh -c 'ls -la ~/.codex; cat ~/.codex/config.toml'` and compare with the S2 snapshot | Which hooks run only with the flag; the review UI; where approval is stored (file, section, hash), and whether a second `codex exec` without the flag now fires the hooks | Stored trust that a startup step can write -> pre-trust only ai-memory's hooks, ship no bypass. No stored trust -> consult S7c. |
| S7c | `! rm -f ~/spike/claude-work/.hook-fired; sbx create --name hook-parity --kit "$PWD/agent" jarvis-engineer ~/spike/claude-work` (run from the repo root), then `! sbx run hook-parity`, note whether Claude shows any trust or hook-approval prompt, exit, then `! ls -la ~/spike/claude-work/.hook-fired` | Prompt shown (yes/no); hook ran (yes/no). Interactive on purpose: print mode skips the trust dialog and would bias the answer | Ran with no prompt -> parity: bypass is acceptable if S7b found no stored trust. Prompted or blocked -> no parity: ship Codex with MCP-only memory and make hooks an explicit opt-in (ADR D6). |
| S8 | Create a second sandbox with a non-secret probe variable: `! printf 'SPIKE_PROBE=probe-123\n' > ~/spike/probe.env; sbx rm --force codex-spike; sbx create --name codex-spike --env-file ~/spike/probe.env --kit ~/spike/codex-spike codex-spike ~/spike/work`; register a probe MCP: `! sbx exec codex-spike -- sh -c 'codex mcp add probe -- sh -c "env > /home/agent/mcp-env.txt; sleep 20"; codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "say hi" >/dev/null 2>&1; grep SPIKE_PROBE /home/agent/mcp-env.txt; codex mcp add --help \| head -30'` | Does the stdio server receive `SPIKE_PROBE`? If not, the name of any env-forwarding key (names in config, values from env); retest with it by editing `~/.codex/config.toml` | Reaches the server, or a forwarding key works -> register the MySQL server with no values in config. Neither -> no MySQL MCP on Codex in v1. Never put MySQL values in config. Use no real credentials in this test. |
| S10 | `! docker run --rm --user 1000:1000 --entrypoint sh docker/sandbox-templates:codex-docker -c 'command -v codex node npm npx jq git dockerd docker; codex --version; node --version; npm config get prefix; id; ls -ld ~ ~/.codex ~/.agents 2>&1'` and `! docker image inspect docker/sandbox-templates:codex-docker --format '{{json .Config.Labels}} {{.Config.User}} {{.Config.Entrypoint}}'` | Presence of `node`/`npm`/`npx`, the `start-docker` label, user, npm global prefix (the Claude image uses `/usr/local/share/npm-global`), absolute path of `codex`, version | Node missing -> install it in `Dockerfile.codex`. Label missing -> stop and return to the architect (nested Docker is a stated capability). Record the codex version and the npm prefix. |

Cleanup: `! sbx rm --force codex-spike hook-parity; rm -rf ~/spike`.

Spike results (fill in; this is the gate for Phase 3):

| # | Result | Evidence (path or pasted output) | Decision flag |
|---|--------|----------------------------------|---------------|
| S1 | Loaded directly from the kit paths. Codex quoted `SPIKE-GLOBAL-LINE-1` from `~/.codex/AGENTS.md`, listed `jarvis-big`, `jarvis-ro` and `jarvis-spike` next to its built-ins (`default`, `explorer`, `worker`), and listed both `.agents/skills` skills next to its bundled ones. No copy step needed. Re-run with `-m gpt-5.6-terra`. | `~/spike/s1.txt`, `s1-files.txt` | `content-path: direct` |
| S2 | `~/.codex/config.toml` exists right after create, before Codex ever starts (613 bytes, written by sbx at create time). It sets `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`, `forced_login_method = "api"`, `model_provider = "sandboxd"` (proxy at `chatgpt.com/backend-api/codex`), and an `mcp_servers.mcp-gateway` HTTP server. `~/.codex/auth.json` is also written. Startup steps must merge into this file, not replace it. | `~/spike/s2.txt` | |
| S3 | `spike-extra` (with Claude-only `model:`/`paths:` keys) is listed like any other skill. No warning or error in the output. Extra keys are tolerated, and the source allows only `name`/`description` anyway. | `~/spike/s1.txt` | |
| S4 | `G-20; P-20`: the full 20,140-byte global and 20,120-byte project `AGENTS.md` were both seen, about 40 KiB combined. No separate cap at 20 KiB and no combined cap at 32 KiB at these sizes. This is the model's self-report; the markers were unique and it named the last one in both files. `codex execpolicy` is a policy checker (`check`), not a rules loader, and `probe.md` in `~/.codex/rules` produced no warning. | `~/spike/s4.txt` | `agents-md-budget: 16384` (ADR default kept; at least 20,140 bytes measured as safe) |
| S5 | Both agents found and invoked by their hyphenated names. `jarvis-spike` replied `SPIKE-AGENT-OK`. `jarvis-big` reported `B-32`, its last marker, so a 32,295-byte `developer_instructions` was not cut off. | `~/spike/s5.txt` | `agent-cap: none` (at 32 KB) |
| S6 | **Not enforced.** `jarvis-ro` (with `sandbox_mode = "read-only"`) wrote `/home/agent/ro-probe.txt`; the control `rw-probe.txt` was also written. Both are on disk, which is the filesystem evidence, not just the model's report. The parent session runs `danger-full-access` (sbx's `config.toml`, S2), and the per-agent key did not restrict the sub-agent. | `~/spike/s6.txt` | `ro-enforced: no` (prompt-only, I7; no `codex.sandbox_mode` key) |
| S7 | `features.hooks` is `stable true` by default, so no startup step is needed for it. In a fresh sandbox (the S8 one), `codex exec` without the bypass flag ran **no** hooks and stored no trust. `--dangerously-bypass-hook-trust` exists and runs them: S7b-flag, both logs written. Approving the hook review interactively stores trust in `~/.codex/config.toml`, one table per handler: `[hooks.state."<hooks.json path>:<event>:<group>:<handler>"] trusted_hash = "sha256:..."`. Global and project hooks are keyed separately. After approval, `codex exec` without the flag runs them (S7b). The hash is Codex's `hook_hash()` (`codex-rs/hooks/src/engine/discovery.rs`): `version_for_toml` over a normalized `{event, matcher group, handler}` identity, not a hash of the JSON or command text, and no CLI sets it. It can still be pre-trusted: the key path is fixed (`/home/agent/.codex/hooks.json`), and the hooks come from pinned `ai-memory install-hooks`, so the hashes are stable for a pinned ai-memory and Codex pair. Capture them once from an approved sandbox and have a startup step merge them into `config.toml`. `verify-sandbox` must then assert the hooks fire, so a version bump that changes the hashes fails loudly. S7c (Claude parity) not run. Not needed for the decision, since stored trust exists. | `~/spike/s7a.txt`, `s7b-flags.txt`, `s7b-flag.txt`, `s7b.txt` | `hook-mode: pretrust` (captured hashes) |
| S8 | `SPIKE_PROBE` is in the sandbox environment, but the stdio MCP server's environment contains only `HOME NODE_EXTRA_CA_CERTS PATH PWD REQUESTS_CA_BUNDLE SSL_CERT_FILE`: Codex does not pass the environment through by default. `codex mcp add --env KEY=VALUE` writes the **value** into `config.toml`, which is not allowed. The names-only key works: with `-c 'mcp_servers.probe.env_vars=["SPIKE_PROBE"]'`, the server's environment contains `SPIKE_PROBE` (count 1, `~/spike/s8b.txt`). Register MySQL with `env_vars = ["MYSQL_HOST", "MYSQL_PORT", "MYSQL_USER", "MYSQL_PASS"]` and no values. | `~/spike/s8.txt` | `mysql: forward` (`env_vars`) |
| S9 | Partial. `sbx kit inspect codex` is rejected: built-in agents are not a kit reference (`not a local path and does not look like a registry reference`). `sbx kit inspect` on a kit shows only that kit's own fields, never the inherited parent's, so it cannot show the inherited `command`, allowlist or credentials. The inherited Codex config is visible in S2 instead. Still to get: the inherited allowlist, from a live sandbox (`sbx policy`, or whatever `sbx --help` offers). | `~/spike/s9-codex.txt` | |
| S10 | `codex-cli 0.149.1` at `/usr/local/share/npm-global/bin/codex`. `node` v22.22.1, `npm`, `npx`, `jq`, `git`, `dockerd`, `docker` all present. npm prefix `/usr/local/share/npm-global` (same as the Claude image). User `agent` uid 1000, `HOME=/home/agent`, entrypoint `tini --`. `com.docker.sandboxes.start-docker=true`, base `ubuntu:questing` (26.04). `~/.codex` exists in the image and `~/.agents` does not. The image's `agent` is not in the `docker` group, but a live sandbox's is (gid 1001), so sbx adds it. | `~/spike/s10.txt` | `node: present`; `npm-prefix: /usr/local/share/npm-global` |

Blockers found while running Phase 2 (2026-10-09):

- `sbx create` printed `Note: no binding authorizes openai — the credential was not injected. Create a binding (re-run
  interactively, or edit ~/.config/sbx/credentials.yaml) to use it.` The global `openai` OAuth secret exists, but no
  binding authorizes it for this sandbox. Create the binding before S1/S3–S8. It is probably needed for the Phase 3 kit too.
- Claude Code's auto-mode classifier refuses to run `codex exec --dangerously-bypass-approvals-and-sandbox` for the
  assistant. Every item that runs Codex (S1 loading, S3–S8) is therefore left for the user, as section 4's title intended.
  The sandbox `codex-spike` is kept for those runs.
- `codex exec` launched through `sbx exec` waits forever (`Reading additional input from stdin...`) unless stdin is
  `</dev/null`. Phase 3 startup steps and live checks that call `codex exec` need the same redirect.
- Every model call failed with `The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account.`
  `gpt-5.6-sol` is the catalog default (`codex debug models`). The catalog also lists `gpt-5.6-terra`, `gpt-5.6-luna`,
  `gpt-5.5` and `gpt-5.2`. Re-ran S1, S3–S6 with `-m gpt-5.6-terra`, which the account accepts. The Phase 3 kit has to pin it
  (`model = "gpt-5.6-terra"` merged into `config.toml`, or `-m` in the kit `command`).

Hook-mode decision order (U3, ADR D6): stored trust available (S7b) -> `pretrust`; else Claude parity (S7c) -> `bypass`; else `mcp-only`.

## 5. Phase 3: Codex kit (gated on Phase 2)

Every step starts RED, as in Phase 1. Paths marked (S1) switch on the S1 flag.

| Gate | Steps it changes |
|------|------------------|
| S1 `restore-step` | 3.2 output paths, 3.5 gains a copy startup step, step count changes |
| S4/S5 numbers | generator budget constants in 3.2, size tests |
| S5 not discovered / S10 label missing | stop; return to the architect |
| S6 | whether `codex.sandbox_mode` is allowed (3.2) and set (3.1) |
| S7 | startup steps and `command` flags in 3.5 |
| S8 | whether the mysql step exists in 3.5 and in the live tier |
| S9, S10 | allowlist, `command`, Dockerfile contents and asserts |

### Step 3.1 Decide rule bindings and per-role Codex keys

- Needs the user (not blocking Phase 1). The ADR gives only the coder example. Proposal, based on what the legacy kits shipped:
  coder `rules: [code-style, testing, golang-idioms, conventional-commit]`; reviewer `[code-review]`; refactorer
  `[code-style, testing, golang-idioms]`; architect, planner, investigator, expert none. Confirm or change.
  Add `codex.sandbox_mode: read-only` to the five read-only roles only if S6 passed.
- Files: `shared/agents/*.md` (add `rules:` and `codex.*`). Claude output must not change: `--check` for `agent/` stays green.

### Step 3.2 Codex output target in the generator (RED then GREEN)

- Files: `scripts/test-sync-agents.sh`, `scripts/sync-agents.sh`, `shared/role/delegation.codex.md` (new).
- Change: kit `agent-codex/files/home`, owned (S1 direct): `.codex/AGENTS.md`, `.codex/agents/*.toml`, `.agents/skills/`,
  `.jarvis/rules/*.md` (S1 restore-step: `.jarvis/codex/{AGENTS.md,agents,skills}` plus `.jarvis/rules`).
  - TOML per agent: `name`, `description` as TOML basic strings, `codex.<k>` keys as `<k> = ` (allowlist:
    `codex.model_reasoning_effort`, and `codex.sandbox_mode` only if S6 passed), `developer_instructions` as a multi-line
    basic string = body + declared rules, in the order declared. Escape `\` and `"""`; fail rather than corrupt
    content it cannot encode. `claude.*` never reaches Codex.
  - Rules for Codex: strip a leading frontmatter block before inlining or copying to `.jarvis/rules` (the `paths:` header is a
    Claude feature and is noise in a prompt).
  - `AGENTS.md` = `shared/role/ROLE.md` + one blank line + `delegation.codex.md` + a generated rules index (name, first heading, absolute
    path `/home/agent/.jarvis/rules/<name>.md`); fail above the S4 budget (ADR default 16 KiB). `delegation.codex.md`
    states: custom agents are in `~/.codex/agents`, invoke them by `jarvis-*` name (syntax from S5), rules index location, no workflow section.
  - Fail when a `developer_instructions` exceeds the S5 cap, if one was found. Skills copied byte for byte.
  - Cross-target checks: Claude output unchanged; a rule missing from the index fails `--check`.
- Accept: new Codex `emit`/`reject`/`check` cases fail first, then pass; Phase 1 cases still pass; `agent/` regeneration is a no-op.
- Run: `./scripts/test-sync-agents.sh`; `./scripts/sync-agents.sh --check`.

### Step 3.3 `Dockerfile.codex` and version-pin parity

- Files: `Dockerfile.codex` (new), `scripts/verify-image-codex.sh` (new), `scripts/verify-image.sh`, `Makefile`.
- Change: `FROM docker/sandbox-templates:codex-docker` (floating tag, like the Claude Dockerfile; no tag is pinned today). `USER root`; same `AI_MEMORY_VERSION` and `GOLANGCI_LINT_VERSION`
  ARGs and install layers as `Dockerfile` (mise, ai-memory copy plus hooks bundle, `@benborla29/mcp-server-mysql`, golangci-lint); install
  node only if S10 says it is missing; no `config.json`, plugin scripts or statusline. Final asserts as in the Claude Dockerfile
  minus plugins, plus `codex --version`, `hooks/codex/session-start.sh` executable, dockerd, `docker` group. `USER agent`.
  `verify-image-codex.sh` (RED first against a missing image) cases: ai-memory path and version, codex hook bundle, `install-hooks --agent codex`
  writes `/usr/local/bin/ai-memory` and no `/opt/mise` into `hooks.json`, `install-mcp --client codex` is idempotent and keeps an unrelated `[mcp_servers.x]`,
  `ai-memory init`, `mcp-server-mysql` under the S10 npm prefix, `codex --version`, `start-docker` label, dockerd/docker/compose/buildx, `agent` in group `docker`.
  Pin parity: both `verify-image*.sh` assert the built image's ai-memory and golangci-lint versions equal the ARG in both Dockerfiles, so bumping one file
  fails the job that builds the other.
- Run: `make build-codex && make verify-image-codex && make verify-image`.

### Step 3.4 Family-aware `verify-kits.sh` (RED then GREEN)

- Files: `scripts/verify-kits.sh`.
- Change: `family_of <kit>` from the spec's `extends:` (`claude` or `codex`); Claude-only cases (`restore-claude-plugins`, `jarvis-statusline --install`,
  `CLAUDE=`, `9 startup`, role label) run for the Claude family only; `BASE_ALLOW` becomes common plus per-family (`code.claude.com` Claude only, plus the S9 hosts for Codex).
  Codex cases: validates; inspect shows `jarvis-engineer-codex:latest`; `extends: codex`; both flags pinned per S7/S9; `--client codex`, and `--agent codex` unless `hook-mode: mcp-only`;
  no `claude mcp`, `restore-claude-plugins`, `jarvis-statusline`; no `OPENAI_API_KEY`; mysql step present only if `mysql: forward`; `AGENTS.md` under budget;
  step count equals the spec. Cross-family invariants: `AI_MEMORY_DATA_DIR` value, volume path and size, serve bind, readiness text, chown step, no `MYSQL_*` in `environment`.
  The within-family drift loop stays (vacuous with one kit per family).
- RED: add `agent-codex/` expectations before the kit exists (shim as in 1.8). GREEN with 3.5.

### Step 3.5 The `agent-codex/` kit

- Files: `agent-codex/spec.yaml`, `agent-codex/files/home/.jarvis-role`, generated content from 3.2.
- Change: `schemaVersion "2"`, `kind: sandbox`, `name: jarvis-engineer-codex`, `extends: codex`, `sandbox.image: jarvis-engineer-codex:latest`,
  `sandbox.command` = `--dangerously-bypass-approvals-and-sandbox`, plus `--dangerously-bypass-hook-trust` only if `hook-mode: bypass`.
  Network: common base plus S9 hosts plus the two registry hosts (same as `agent/`). Same `AI_MEMORY_DATA_DIR` env, 5g volume, chown install step.
  Startup (adapt to flags): clear serve lock; `ai-memory init`; `install-mcp --client codex --apply`; `install-hooks --agent codex --apply` (not for `mcp-only`);
  S1 copy step if needed; serve (background, same bind); readiness poll (same text, always exit 0); mysql registration (only for `mysql: forward`, same guards,
  absolute codex path from S10, `exit 0`, no values passed). Pre-trust step only for `hook-mode: pretrust`, always exit 0. No `credentials:`, no `OPENAI_API_KEY`.
  `.jarvis-role` is hand-owned per the ADR; Codex has no statusline consumer, so it is presence-checked only.
- Run: `./scripts/sync-agents.sh`; `PATH=$TMPDIR/shim:$PATH ./scripts/verify-kits.sh` then real `make verify-kits` on the host.

### Step 3.6 Live tier and Makefile

- Files: `scripts/verify-sandbox-codex.sh` (new), `Makefile`.
- Change: live cases: ai-memory handshake, store on the volume owned `agent:agent`, MySQL reachability and greeting (copied from `verify-sandbox.sh`,
  not factored into `scripts/lib/`: refactoring the live Claude script has no CI coverage), `codex mcp list` shows `ai-memory` (and `mysql` if configured),
  `~/.codex/config.toml` has no `MYSQL_(PASS|USER)`, `~/.codex/AGENTS.md` equals the kit file and starts with the generated marker, agents listed, hooks file has ai-memory events
  (`hook-mode` permitting), the four Docker cases. Makefile: `CODEX_IMAGE`, `build-codex`, `verify-image-codex`, `template-codex`, `sandbox-codex`
  (`KIT=agent-codex SANDBOX=jarvis-engineer-codex`, runs `verify-sandbox-codex.sh`), `.PHONY`, and `verify` includes `verify-image-codex`.
- Run (host): `make template-codex && make sandbox-codex`. Manual once: `codex exec` quoting `AGENTS.md` line 1 and invoking `jarvis-coder` (costs tokens).

### Step 3.7 CI and docs

- Files: `.github/workflows/ci.yml`, `.github/dependabot.yml` (maybe), `CLAUDE.md`, ADR, this file.
- Change: job `image-codex` (`make build-codex`, `make verify-image-codex`). Dependabot's docker updater scans a directory for Dockerfile-named files, so the existing `directory: /`
  entry may already cover `Dockerfile.codex` (unverified; the ADR says an entry is needed): check the first Dependabot run and add nothing speculative.
  `CLAUDE.md`: Codex kit section (image, kit, content path, make targets, tiers), updated verification tiers and known gaps (no statusline or plugins, hook-mode, workflows not ported).
  Fill in the spike results; mark the ADR implemented.
- Run: full gate: `make verify-sync verify-image verify-image-codex verify-kits`, `go build ./... && go vet ./...`, host `make sandbox` and `make sandbox-codex`.

## 6. Risks and assumptions

- R1 Portability. Scripts written and tested on bash 5.3/mawk here run on macOS bash 3.2/BSD tools on the host. Mitigation: the constraints in section 0 and the macOS CI leg.
- R2 Byte exactness. Six sources lack a trailing newline; any `read`/`awk print` emission silently changes them. Covered by tests and step 1.7 check 3.
- R3 Generated markers are new text in system prompts (agents, rules, `ROLE.md`). Effect on behavior is not verified; step 1.11 checks live; removal is one constant.
- R4 `ROLE.md` changes (I3, I4) alter the orchestrator prompt; they are what the ADR specifies (section 6), limited to relocating existing text. Larger fragment content is not included unless asked.
- R5 `golang-idioms.md` has nested `paths:` frontmatter and is not "always-on" as the ADR describes the rules. Phase 1 passes rule frontmatter through untouched. For Codex it is stripped (3.2), so the Go
  rule becomes unconditional for any Codex agent that declares it.
- R6 `verify-kits.sh` and everything `sbx` cannot run in CI or in this sandbox. The shim checks script logic only. Real `make verify-kits` and `make sandbox` on the host are required before merge.
- R7 Branch protection must be updated by the user for the new `sync` job; until then it is advisory.
- R8 Legacy loss is real: `REVIEWER.md` depth, per-role least-privilege network, single-role sandboxes. It is listed in 1.1 and recoverable from git history.
- R9 Spike answers for S4 and S5 rely on the model reading its own context; flag discrepancies instead of trusting a single run.
- R10 Phase 3 assumptions not yet tested: `codex-docker` runs as uid 1000 `agent` with `HOME=/home/agent`; Codex agent TOML fields are `name`, `description`, `developer_instructions`, `sandbox_mode`, `model_reasoning_effort`;
  coder's inlined prompt is about 29 KB before the marker.
- Blocking Phase 1: nothing. Needs the user later: 3.1 rule bindings; the U3 order confirmation; branch-protection change; host runs of `make verify-kits` and `make sandbox`.
