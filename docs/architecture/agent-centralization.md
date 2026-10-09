# ADR: One source of truth for agents, rules, and skills across Claude Code and Codex kits

Status: IMPLEMENTED (accepted 2026-10-08, implemented 2026-10-09). Where the implementation
departs from this record (hook pre-trust computed at startup through Codex's app-server instead of
baked hashes, the bypass flag inherited from the built-in entrypoint rather than repeated, Codex
agent files named after `name`), the reasons are in `docs/plans/codex-agent-support.md` and
`CLAUDE.md`.

Supersedes: D2 and D3 of `docs/plans/codex-agent-support.md` (coder-only pilot under `agents-codex/`).
Keeps: that plan's facts, capability map, R1-R8, and its Codex startup-step design, except where noted.

## 1. Context

### Problem

1. Users want a Codex sandbox kit with the same orchestrator persona, sub-agents, rules, and skills
   as the unified Claude kit (`agent/`).
2. The same role content already exists in more than one place, and the copies have drifted with
   nothing checking them. Adding Codex as a third consumer, maintained by hand, would make this
   worse.

Evidence of current drift (measured, not assumed):

- `agent/files/home/.claude/agents/<role>.md` and `agents/<role>/files/home/<role>.md` differ for
  every one of the six roles compared: architect 15 diff lines, coder 6, planner 35, refactorer 85,
  investigator 103, expert 146.
- `agents/coder/.../rules/code-style.md` differs from `agent/.../rules/code-style.md` (the legacy
  copy has a "Language-specific guides" section pointing to `/home/agent/GOLANG_IDIOMS.md`).
- Legacy `REVIEWER.md` is 6.7 KB, while the unified `reviewer.md` is 1.5 KB and leans on
  `rules/code-review.md`. The two have different structures, so neither one is a copy of the other.
- `scripts/verify-kits.sh` globs `agents/*/spec.yaml`, so `agent/` (the Makefile default kit) has no
  kit-level checks at all.
- `agent/.../agents/reviewer.md` closes its frontmatter with a long run of dashes rather than
  `---`. Claude tolerates this, but a strict parser does not. This is a latent defect of the kind a
  generator surfaces.

### Existing invariants this decision must preserve (from `CLAUDE.md` and the repo)

- **I1. A kit directory is self-contained.** `sbx create --kit <dir>` consumes it directly, and
  nothing runs between checkout and `sbx create` except `make` (which is optional).
- **I2. Duplication is allowed, but every duplicate has a drift check.** The shared spec block is
  copied verbatim on purpose, and `verify-kits.sh` byte-compares the copies. The repo's established
  answer to "we can't factor this out" is "copy it, then mechanically assert the copies agree".
- **I3. "Survives a fresh `sbx create`" is the bar.** Any state that `sbx create` resets
  (settings-only keys) is restored by an idempotent, always-exit-0 startup step from a path outside
  the reset area.
- **I4. Startup steps never fail hard.** A non-zero step silently aborts every later step.
- **I5. Secrets never live in specs or config files.** `MYSQL_*` come from `--env-file`, and auth
  stays on the host (`sbx secret set`).
- **I6. Three verification tiers:** image (static, runs in CI), kit (needs `sbx`, not in CI), and
  sandbox (live).
- **I7. Read-only roles are enforced by the prompt only.** This is a known gap, not an invariant to
  keep. Codex may be able to close it (see D1 and S6).

## 2. Decisions summary

| #  | Decision |
|----|----------|
| D1 | Canonical source is `shared/`, in Markdown with a **flat** YAML frontmatter subset. Agent metadata is target-neutral (`name`, `description`, `rules`). Target-specific keys are namespaced (`claude.*`, `codex.*`), and the generator never translates between them. |
| D2 | Generated output is **committed** into each kit's `files/home`. The generator owns an explicit set of subtrees. `sync-agents.sh --check` regenerates into a temp dir and diffs exactly, and **it runs in CI** (unlike `verify-kits.sh`). No symlinks. |
| D3 | Rules are **not** folded wholesale into Codex `AGENTS.md`. Each Codex sub-agent embeds the rules its role declares in `developer_instructions`. The orchestrator's `AGENTS.md` holds the role plus a rules index pointing at the rule files on disk. ROLE.md becomes a neutral core plus a per-target "delegation mechanics" fragment, concatenated with no templating. |
| D4 | Separate `Dockerfile.codex` built `FROM docker/sandbox-templates:codex-docker` (the planner's option A). A new kit `agent-codex/`, with `agent/` left where it is. Verifiers become family-aware, keyed on `extends:` in the spec, and `agent/` joins kit verification. |
| D5 | Legacy `agents/*/` kits: **retire** them (recommended). Generating them is the fallback. This is a user decision. Hand-maintaining them under centralization is rejected either way. |
| D6 | Accept `--dangerously-bypass-hook-trust` **only if** the spike shows that the Claude kit already runs repo-shipped project hooks under sbx (posture parity). Prefer targeted pre-trust of ai-memory's hooks if Codex persists trust. Otherwise ship MCP-only memory. |
| D7 | Spike gates only the Codex kit. Each unknown has a predefined fallback that does not change D1 to D3 (section 10). |

## 3. Architecture

### Components and ownership

```
shared/                          SOURCE OF TRUTH (hand-edited, target-neutral)
  role/ROLE.md                   orchestrator core: responsibilities, workflows, boundaries
  role/delegation.claude.md      how to delegate in Claude Code (.claude/agents, Agent tool, workflows)
  role/delegation.codex.md       how to delegate in Codex (invoke agents by name, rules index location)
  agents/<role>.md               frontmatter + neutral body, one file per role
  rules/*.md                     always-on standards
  skills/<name>/SKILL.md         agentskills.io standard keys only

scripts/sync-agents.sh           GENERATOR (pure function: shared/ -> kit subtrees). --check = drift gate

agent/        (Claude kit)       hand-owned: spec.yaml, .jarvis-role, .claude/settings.json, .claude/workflows/
                                 generated:  ROLE.md, .claude/agents/, .claude/rules/, .claude/skills/
agent-codex/  (Codex kit)        hand-owned: spec.yaml, .jarvis-role
                                 generated:  .codex/AGENTS.md, .codex/agents/*.toml,
                                             .agents/skills/, .jarvis/rules/*.md

Dockerfile          -> jarvis-engineer:latest        (Claude, unchanged)
Dockerfile.codex    -> jarvis-engineer-codex:latest  (Codex)
```

Ownership rules:

- `shared/` owns **content**, meaning what an agent is and how it behaves.
- A kit owns **runtime wiring**, meaning the spec, settings, launcher flags, and the startup steps
  that register MCP servers and hooks. Target configuration (`settings.json`, `config.toml`) is
  never generated from `shared/`. The two have different semantics, and ai-memory's startup steps
  already write `config.toml`.
- Claude-only capabilities that have no Codex equivalent (`.claude/workflows/*.js`) stay hand-owned
  in `agent/`. They are explicitly not ported (section 11).

### Data and control flow

```
edit shared/** --> sync-agents.sh --> agent/files/home/**, agent-codex/files/home/** (committed)
                                           |
                     CI: sync-agents.sh --check (fails on any hand-edit or stale output)
                                           |
              sbx create --kit agent | agent-codex  (consumes the kit dir directly; invariant I1 holds)
```

## 4. D1: Canonical format for agent definitions

**Decision.** The canonical format is Markdown with YAML frontmatter, which is the format the repo
already uses. Claude agents and agentskills SKILL.md use it too. The frontmatter is restricted to a
**flat subset**: `key: scalar` and `key: [a, b]` only, with no nesting and no multi-line values.
The generator rejects anything else, including unknown keys.

```yaml
---
name: jarvis-coder                      # required, identical on both targets
description: Implements code ...        # required, identical on both targets
rules: [code-style, testing, golang-idioms, conventional-commit]   # neutral; consumed by Codex
claude.model: sonnet                    # optional, emitted only to Claude as `model:`
claude.skills: [superpowers:systematic-debugging]   # Claude plugin skill; Codex has no equivalent
codex.model_reasoning_effort: high      # optional, emitted only to Codex TOML
codex.sandbox_mode: read-only           # optional; see S6
---
<neutral role body>
```

Mapping:

| Source key | Claude `.claude/agents/<r>.md` | Codex `.codex/agents/<r>.toml` |
|---|---|---|
| `name`, `description` | frontmatter | `name`, `description` |
| body | body | `developer_instructions` (body + declared rules, D3) |
| `rules` | dropped (Claude loads `~/.claude/rules` globally) | rules inlined into `developer_instructions` |
| `claude.<k>` | `<k>:` | dropped |
| `codex.<k>` | dropped | `<k> =` |

Rationale:

- **No cross-target translation**, which means no automatic `model: sonnet` to Codex model and no
  `tools:` to `sandbox_mode`. The two vocabularies are not semantically equivalent. A silent mapping
  would encode a guess as a contract. Explicit namespaced keys make every target-specific decision
  visible in review.
- A flat subset keeps the generator stdlib-only (bash/awk) with no `yq`, YAML library, or `go.sum`
  added to a dependency-free module. If the format ever needs nesting, move the generator to Go
  under `cmd/`. Do not add `yq`.
- Strict rejection turns latent defects such as reviewer.md's malformed delimiter into build
  failures.
- TOML emission constraint: `developer_instructions` is written as a basic multi-line string with
  `\` and `"""` escaped. The generator fails rather than silently corrupting content it cannot
  encode.
- Skills: the canonical SKILL.md files may use only the agentskills standard keys (`name`,
  `description`, plus the standard's optional ones). The four current skills already comply, so the
  question of whether Codex tolerates Claude-only keys (S3) does not block anything. They are copied
  byte for byte to both targets.

## 5. D2: Generate, commit, enforce

**Decision.** Generate the output, commit it, and enforce it with `--check` in CI.

- The generator owns an **exact list of subtrees** per kit (section 3). `--check` regenerates
  into a temp dir and runs `diff -r` against exactly those subtrees. An extra file, a missing file,
  or a modified file all fail the check. Hand-owned paths are never touched or compared.
- Each generated file starts with a one-line "generated from shared/...; edit there" marker, where
  the format allows a comment. TOML allows one. Markdown with frontmatter allows a comment only
  after the frontmatter, and SKILL.md is left byte-identical so it gets no marker.
- `--check` needs only bash, so it runs in the existing CI `go` job or a new tiny job. This matters
  because `verify-kits.sh` is not in CI (it needs `sbx`). A drift gate that only runs on a
  developer's machine is how the current drift happened.
- `verify-kits.sh` also calls `sync-agents.sh --check`, so a local `make verify` covers it.
- Makefile: add `make sync` (regenerate) and `make verify-sync` (check), and have `verify` depend
  on `verify-sync`.

| Option | Advantages | Disadvantages | Verdict |
|---|---|---|---|
| **Generate + commit + CI check** | Kits stay self-contained (I1). Output is reviewable in PRs. Same "copy + assert" pattern as the spec block (I2). No sbx behavior assumptions. | Diffs show both source and output, and contributors must run `make sync`. | **Chosen** |
| Symlinks from kits into `shared/` | No duplication, no generator | Whether sbx follows symlinks in `files/home` is unverified. Codex needs different shapes (TOML, inlined rules), so symlinks cannot produce them anyway. | Rejected |
| Generate at `make sandbox` time, output git-ignored | No committed duplicates | Breaks I1: `sbx create --kit agent` straight from a checkout gets an empty kit. Output is invisible to review. | Rejected |
| Bake `shared/` into the image and copy at startup | Sidesteps the overlay-survival unknown | Every content edit needs an image rebuild. Splits ownership of kit content between image and kit. | Rejected as primary. Kept as the S1 fallback mechanism, in kit-side form (S1, section 10). |

## 6. D3: How rules and ROLE.md reach Codex

### Rules

Measured: ROLE.md (6.0 KB) + all five rules (29.4 KB) = 35.4 KB. That exceeds the 32 KiB
`project_doc_max_bytes` default before any workspace `AGENTS.md` is counted. Folding everything in
is therefore not viable.

**Decision.** Bind rules to the agents that use them.

- Each Codex sub-agent's `developer_instructions` = role body + the rules listed in its `rules:`
  key. The rules are inlined, so they are always-on for that agent, which matches Claude semantics
  where rules always load.
- The orchestrator's `~/.codex/AGENTS.md` = `role/ROLE.md` + `role/delegation.codex.md`, plus a
  generated **rules index** (name, one-line purpose, absolute path) pointing at
  `/home/agent/.jarvis/rules/*.md`. The orchestrator reads a rule on demand when it edits code
  itself.
- The generator enforces a byte budget on `AGENTS.md`, set at 16 KiB to leave headroom for the
  repo's own `AGENTS.md` (pending S4), and fails if the budget is exceeded.
- Location: rule files go under `~/.jarvis/rules/`, not `~/.codex/rules/`. Codex uses
  `~/.codex/rules/` for its command execution-policy files (**to verify**, S4), and a collision
  there would be misparsed or ignored.

This also fixes a scoping smell that exists today in the Claude kit for the Codex side only.
`rules/code-review.md` ends with "If there are zero actionable issues, reply with exactly: No
actionable issues found", and Claude loads that rule into the orchestrator and every sub-agent.
Per-agent binding confines it to the reviewer. Do not change Claude's global-rules behavior in this
work. Changing it is a separate decision.

| Option | Verdict |
|---|---|
| Fold all rules into AGENTS.md | Rejected. It is over the cap today, and silent truncation is the failure mode. |
| Convert rules to Codex skills | Rejected. It changes the semantics from always-on to model-chosen, and coding standards then apply only when the model decides they are relevant. |
| **Per-agent inlining + orchestrator index** | **Chosen.** It keeps always-on semantics where the work happens and bounds AGENTS.md. Depends on S5 (no tighter cap on `developer_instructions`; the coder would be about 29 KB). |

### ROLE.md and Claude-specific references

ROLE.md is about 95% target-neutral. Its Claude-specific content is line 4 ("defined in
`.claude/agents`"), the implicit Agent tool, and the workflow. Split it into the neutral core plus
one **delegation-mechanics fragment per target**, then concatenate. Do not use placeholders or a
templating language, because a template engine is a new abstraction that the problem does not need.

- `delegation.claude.md` covers sub-agents in `~/.claude/agents`, delegation through the Agent tool,
  and the `implement-review-loop` workflow.
- `delegation.codex.md` covers custom agents in `~/.codex/agents`, invoking agents by name, and the
  rules index. It has no workflow section.
- Sub-agent bodies are already neutral. A `grep` finds no Claude tool or path references in
  `agents/*.md`, and the generator should keep it that way by failing on `.claude/` or
  `subagent_type` in neutral sources.
- Fix one naming inconsistency at seed time: ROLE.md refers to `investigator`, `coder`, and so on,
  while the agents are named `jarvis-investigator` and so on. Neutral text should use the canonical
  `name`.

## 7. D4: Image, kit layout, verification

**Image: separate `Dockerfile.codex` FROM `codex-docker`** (the planner's option A).

| Option | Advantages | Disadvantages | Verdict |
|---|---|---|---|
| **A: `Dockerfile.codex` FROM `codex-docker`** | Uses the base `extends: codex` is documented against (launcher, proxy/certs, start-docker label). No dead Claude plugin layers. Failure of one image cannot break the other. | Shared install layers (ai-memory, mysql-mcp, golangci-lint) and their version ARGs are duplicated | **Chosen** |
| B: add `@openai/codex` to the Claude image | One image, small diff | Diverges from whatever the codex template configures. Couples the two agents' release cadence. Bakes Claude plugins into every Codex sandbox. | Rejected |

The duplication cost under A is handled the repo's way (I2): a static check (in `verify-image*.sh`,
or a grep in CI) asserts that `AI_MEMORY_VERSION` and `GOLANGCI_LINT_VERSION` are equal across both
Dockerfiles. Do not introduce a shared install script just to save three `RUN` lines. Dependabot
needs an entry for `Dockerfile.codex`, and CI gains an `image-codex` job.

**Kit layout: add `agent-codex/` next to `agent/`.** Do not rename `agent/` to `agent-claude/`. The
rename has no architectural benefit right now and would break `KIT ?= agent` and user muscle memory.
It is reversible later.

**Verifiers: family-aware, keyed on the spec's `extends:` value**, rather than on separate
directory globs.

- `verify-kits.sh` discovers `agent/`, `agent-codex/`, and (until D5 resolves) `agents/*`, then
  dispatches per-kit cases by family (`claude` or `codex`). This adds `agent/` coverage, closing an
  existing gap.
- The shared-block drift check stays **within a family**. The Claude family is `agent/` plus
  `agents/*`, which carry the same block. Across families, assert only the invariants that must
  match: the `AI_MEMORY_DATA_DIR` value, the volume path and size, the serve bind address, the
  readiness text, the chown step, and the absence of `MYSQL_*` in `environment`.
- `BASE_ALLOW` splits into a common list plus a per-family addition (`code.claude.com` for Claude
  only).
- Codex-specific kit assertions (no `OPENAI_API_KEY`, pinned `command` flags, `--client codex`,
  `AGENTS.md` under budget) follow the planner's section 6 list.
- Image and sandbox tiers: separate `verify-image-codex.sh` and `verify-sandbox-codex.sh`, because
  most of their cases are target-specific. The agent-neutral live cases (MySQL reachability, nested
  Docker, ai-memory handshake, volume ownership) may move into a sourced `scripts/lib/` file if the
  copy is substantial. That is the planner's call, not an architectural requirement.

## 8. D5: Legacy `agents/*/` kits

They are a fourth copy of the role content, and they have already drifted. Centralization cannot
succeed while they are hand-maintained.

| Option | Advantages | Disadvantages |
|---|---|---|
| **Retire** (delete, drop from verify glob and docs) | Removes the duplication outright, and `KIT ?= agent` already made the unified kit the default | Loses single-role sandboxes. Anyone scripting `--kit agents/coder` breaks. |
| Generate their persona files from `shared/agents/*` | Keeps single-role sandboxes and removes drift | The generator needs a third output shape (persona with rules inlined, as `CODER.md` + `CODE_STYLE.md` are today). Seven more specs to verify. |
| Freeze (out of scope, mark deprecated) | Zero work now | Drift keeps growing, and the source of truth is not single, so the stated goal is not met |

**Recommendation: retire.** **User decision:** whether anyone still uses single-role sandboxes. If
they do, generate them (the generator change is a cheap third output) rather than freeze them.

**Required before seeding `shared/`, whichever option is chosen:** decide which drifted copy is
canonical per role. Recommended: the `agent/.claude/agents` versions (they are what the default kit
ships). The user should review the legacy-only content that would be lost, notably legacy
`REVIEWER.md` versus unified `reviewer.md` + `code-review.md`, and the legacy code-style "Language
guides" section.

**Decided (user, 2026-10-08):** U1 -- retire the legacy `agents/*/` kits. U2 -- where roles drifted,
the `agent/` versions are canonical and seed `shared/`; legacy-only content is listed for review
before deletion, not merged.

## 9. D6: Hook-trust bypass (planner D4)

The threat: `--dangerously-bypass-hook-trust` makes Codex run hooks shipped in the mounted
workspace's `.codex/` with no review. Hooks execute deterministically, without the model choosing
to run them, and with the sandbox environment, which includes `MYSQL_USER`/`MYSQL_PASS` and
proxy-injected GitHub credentials.

Position:

- The **sandbox is the trust boundary**, and the workspace is the user's own project. The agent
  already runs with `--dangerously-bypass-approvals-and-sandbox`, so it can execute anything a hook
  could. The incremental risk is only "code runs without the model in the loop".
- **Accept the bypass only at posture parity:** if the spike (S7) confirms that the Claude kit
  under sbx already executes repo-shipped `.claude/settings.json` hooks without a prompt, Codex with
  the bypass is no worse. This is an assumption, not a verified fact.
- **Preferred:** if Codex persists hook trust (for example, approved hook hashes in
  `config.toml`), a startup step pre-trusts exactly ai-memory's hooks, and the blanket flag is not
  shipped.
- **Otherwise:** ship Codex with MCP-only memory. Make hooks an explicit user opt-in, by a second
  `command` variant or a documented manual flag, rather than the default.
- Any choice keeps I5: no credential ever enters a spec or config. The hook risk is about
  execution, not storage.

**Decided (user, 2026-10-08):** U3 -- decision order, resolved by spike S7: stored Codex trust
available -> pre-trust only ai-memory's hooks; else Claude parity shown -> bypass flag; else
MCP-only memory.

## 10. D7: Spike checklist (gates the Codex kit only)

| # | Question | Pass looks like | Fallback (no change to D1 to D3) |
|---|---|---|---|
| S1 | Do `files/home/.codex/AGENTS.md`, `.codex/agents/*.toml`, and `.agents/skills/**` survive `sbx create` and get loaded (Codex quotes AGENTS.md line 1, lists the custom agents and skills)? | All three present and loaded | Generate into `files/home/.jarvis/codex/**` (outside the reset area) and add an idempotent, always-exit-0 startup step that copies them into `~/.codex` and `~/.agents`. This is the I3 restore pattern, and the content stays kit-owned. |
| S2 | Does `sbx create` write `~/.codex/config.toml` from scratch? | Known either way | The kit ships no `config.toml`. All config is written by startup steps (already the plan). |
| S3 | Does Codex tolerate non-standard SKILL.md keys? | Informational only | None needed. D1 restricts the source to standard keys. |
| S4 | Is the global `~/.codex/AGENTS.md` counted against `project_doc_max_bytes`? What is the real budget? Is `~/.codex/rules/` reserved for exec policy? | Measured numbers | Tune the generator budget, and keep rule files under `~/.jarvis/rules`. |
| S5 | Are custom agents in `~/.codex/agents/*.toml` discovered and invocable by hyphenated name (`jarvis-coder`)? Is there a size cap on `developer_instructions` (coder is about 29 KB)? | Invocable, no cap below 32 KB | If capped, keep the role body and short rules inline, and move long rules (code-style, testing) to on-demand reads via the index with an explicit "read before editing" instruction |
| S6 | Does a sub-agent's `sandbox_mode = "read-only"` hold when the parent runs with `--dangerously-bypass-approvals-and-sandbox`? | Read-only enforced | Prompt-only enforcement, as on Claude (I7). If it passes, set `codex.sandbox_mode: read-only` for investigator, architect, planner, expert, and reviewer. That is the first real enforcement of read-only roles. |
| S7 | Hooks: is `features.hooks` on by default? Is trust persisted, and where? Does the Claude kit run repo `.claude/` hooks unprompted under sbx (parity for D6)? | Facts recorded | D6 decision tree |
| S8 | MySQL credentials for a Codex stdio MCP server: does Codex inherit them, or is there an env-name forwarding key (names in config, values from env)? (planner R1) | Credentials reach the server, and none are written to `config.toml` | No MySQL MCP on Codex in v1. Never write values to config. |
| S9 | `sbx kit inspect codex`: inherited `command`, network allowlist, credentials | Recorded | Pin both flags explicitly (planner R6) |
| S10 | Does `codex-docker` carry `node`/`npm`/`npx` and the start-docker label? | Present | Install node in `Dockerfile.codex` |

The symlink question is dropped from the spike: D2 does not depend on it.

## 11. Explicitly not ported / not changed

- `.claude/workflows/implement-review-loop.js`: no Codex equivalent. The Codex orchestrator runs the
  coder-reviewer loop from ROLE's iterative-workflow prose. Expressing it as a skill would be a new
  capability and needs its own decision.
- Claude plugins (`config.json`, `restore-claude-plugins`) and `jarvis-statusline`: Claude-only.
  `.jarvis-role` stays hand-owned per kit.
- Claude's global loading of `~/.claude/rules` is unchanged.
- `main.go` and its `roles/` gap are untouched.

## 12. Implementation order (for the planner)

1. Reconcile drifted copies and choose canonical content (user, D5). Seed `shared/` from `agent/`.
2. Write the generator for the **Claude target only** and `--check`, wire CI, and regenerate
   `agent/`. The result must be byte-equivalent to today's `agent/` apart from the intended fixes
   (frontmatter delimiter, names). This de-risks centralization independently of Codex.
3. Make `verify-kits.sh` family-aware and add `agent/` coverage.
4. Run the spike (S1 to S10) and record the results in the planner doc.
5. Add the Codex target to the generator, then `Dockerfile.codex`, `agent-codex/`, and the Codex
   verifiers, in the planner's RED-then-GREEN order.
6. Retire or generate the legacy kits (D5).

## 13. Remaining risks

- **Two content shapes for one role.** Claude sees body + global rules, while Codex sees body +
  declared rules. A rule added to `shared/rules` reaches Claude agents automatically but reaches
  Codex agents only if some agent declares it. Mitigation: `--check` fails on any rule that no agent
  declares and that is absent from the index.
- **Behavioral parity is not proven by byte checks.** Generated files can be correct while a target
  ignores them. Only S1, S5, and the live tier prove that content is loaded.
- **Generator scope creep.** Keep it to flat frontmatter, concatenation, and TOML emission. Any
  requirement beyond that (conditionals, templating) is a signal to revisit this ADR, not to extend
  the script.
- Planner risks R1 (MySQL credentials), R2 (hooks not firing), and R8 (two Dockerfiles) still apply.
