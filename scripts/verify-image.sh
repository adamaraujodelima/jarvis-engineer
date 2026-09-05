#!/usr/bin/env bash
#
# Image-level acceptance checks for the jarvis-engineer sandbox template.
#
# Every case asserts an observable output of a command run as the sandbox's
# agent user (uid 1000) -- not merely that a build step exited zero. Tools
# installed as root are invisible to the agent, so root-only checks pass while
# the sandbox stays broken.
#
# Usage: scripts/verify-image.sh [image]

set -uo pipefail

cd "$(dirname "$0")/.."

IMAGE="${1:-jarvis-engineer:latest}"
HOOKS_DIR=/usr/local/share/ai-memory/hooks

# The plugin cases are driven by the same config the build reads, so the suite
# fails when the image and the config disagree rather than when a list hardcoded
# here goes stale.
CONFIG=config.json
IMAGE_CONFIG=/usr/local/share/jarvis-engineer/config.json

plugins=()
while IFS= read -r plugin; do
	plugins+=("$plugin")
done < <(jq -r '.plugins[]' "$CONFIG")

pass=0
fail=0

# check <name> <expected-substring> <shell-command>
#
# Runs the command in the image as uid 1000 and asserts the expected substring
# appears in its combined output.
check() {
	local name="$1" expected="$2" cmd="$3" actual

	actual="$(docker run --rm --user 1000:1000 --entrypoint sh "$IMAGE" -c "$cmd" 2>&1)"

	if [[ "$actual" == *"$expected"* ]]; then
		printf 'ok   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' \
			"$name" "$expected" "${actual:-<empty>}"
		fail=$((fail + 1))
	fi
}

# check_label <name> <expected-substring> <label-key>
#
# Labels drive sbx's own behaviour (it reads them before the container exists),
# so they have to be asserted on the image metadata rather than from inside it.
check_label() {
	local name="$1" expected="$2" actual

	actual="$(docker image inspect "$IMAGE" \
		--format "{{index .Config.Labels \"$3\"}}" 2>&1)"

	if [[ "$actual" == *"$expected"* ]]; then
		printf 'ok   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' \
			"$name" "$expected" "${actual:-<empty>}"
		fail=$((fail + 1))
	fi
}

printf '== image acceptance: %s ==\n' "$IMAGE"

check 'ai-memory resolves on the agent PATH' \
	'/usr/local/bin/ai-memory' \
	'command -v ai-memory'

check 'ai-memory executes as uid 1000' \
	'ai-memory 2.' \
	'ai-memory --version'

check 'claude-code hook bundle sits at the install-hooks default path' \
	'session-start.sh' \
	"ls $HOOKS_DIR/claude-code"

check 'hook scripts are executable by the agent' \
	'EXEC_OK' \
	"test -x $HOOKS_DIR/claude-code/session-start.sh && echo EXEC_OK"

check 'shared hook library is readable by the agent' \
	'READ_OK' \
	"head -1 $HOOKS_DIR/_lib.sh >/dev/null && echo READ_OK"

# claude-code uses ai-memory's native `hook --event` integration rather than the
# shell bundle, so what matters is that the absolute path it writes into
# ~/.claude/settings.json is the stable one -- not a version-pinned mise path
# that a version bump would invalidate.
check 'install-hooks registers the stable binary path' \
	'/usr/local/bin/ai-memory' \
	'AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory install-hooks --agent claude-code'

check 'install-hooks does not leak a version-pinned path' \
	'CLEAN' \
	'AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory install-hooks --agent claude-code 2>/dev/null \
	   | grep -q "/opt/mise" && echo LEAKED || echo CLEAN'

check 'install-mcp targets the loopback server' \
	'127.0.0.1:49374' \
	'AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory install-mcp --client claude-code'

check 'agent can initialise a data directory' \
	'config.toml' \
	'AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1; ls /tmp/v'

check 'mysql mcp server is present for the investigator kit' \
	'mcp-server-mysql' \
	'ls /usr/local/share/npm-global/lib/node_modules/@benborla29'

# --- docker engine ------------------------------------------------------
# sbx decides whether to run the sandbox as docker-in-docker by reading this
# label off the template image, then starts dockerd itself and waits for it.
# Without the label the agent gets the docker CLI and no daemon.
check_label 'image opts in to docker-in-docker' \
	'true' \
	'com.docker.sandboxes.start-docker'

check 'dockerd is present for sbx to start' \
	'/usr/bin/dockerd' \
	'command -v dockerd'

check 'docker CLI resolves on the agent PATH' \
	'/usr/bin/docker' \
	'command -v docker'

check 'compose and buildx plugins are installed' \
	'compose' \
	'ls /usr/libexec/docker/cli-plugins'

# dockerd runs as root and creates the socket root:docker; the agent reaches it
# through the group, so losing that membership breaks every docker command.
# Asserted against /etc/group rather than the current process: `docker run
# --user 1000:1000` sets only the primary gid and drops supplementary groups,
# so a bare `id -nG` would report just `agent` even on a correct image.
check 'agent user is in the docker group' \
	'docker' \
	'id -nG agent'

# --- claude code plugins ------------------------------------------------
# Baking the plugins is the point of the template: a sandbox's ~/.claude is
# recreated per sandbox, so anything installed by hand is gone the next time one
# is created. `claude plugin list --json` is asserted rather than the on-disk
# JSON because it is the same resolution path the agent itself uses -- a plugin
# present in the cache but absent from the settings is not actually loaded.

# An empty list would let every case below pass against an image with no
# plugins at all, so it is a failure in its own right.
if [[ ${#plugins[@]} -eq 0 ]]; then
	printf 'FAIL %s lists no plugins; the cases below would pass vacuously\n' "$CONFIG"
	fail=$((fail + 1))
fi

# The image carries the config it was built from: that is what lets
# `install-claude-plugins` re-run inside a sandbox with no arguments, and what
# makes a mismatch between config and image observable at all.
check 'template ships the config it was built from' \
	"$(cat "$CONFIG")" \
	"cat $IMAGE_CONFIG"

for plugin in "${plugins[@]}"; do
	check "$plugin is installed and enabled" \
		'"enabled": true' \
		"claude plugin list --json | grep -A3 \"$plugin\""
done

# Counted, not just grepped for absence: `grep -c false` on an empty plugin list
# also reports 0, so it would pass against an image with no plugins at all.
check 'every configured plugin is enabled and none disabled' \
	"enabled=${#plugins[@]} disabled=0" \
	'e=$(claude plugin list --json | grep -c "\"enabled\": true");
	 d=$(claude plugin list --json | grep -c "\"enabled\": false");
	 echo "enabled=$e disabled=$d"'

# `plugin install` writes absolute installPaths. Installing as root would record
# /root/.claude/... -- unreadable at uid 1000, exactly the trap mise fell into.
check 'plugin cache is recorded under the agent home' \
	'"installPath": "/home/agent/.claude/plugins/cache' \
	'claude plugin list --json | grep installPath'

# The cache is only half the state: without the marketplace declared in user
# settings, Claude Code cannot refresh or re-resolve the plugin at runtime.
# Derived from the plugin ids rather than from `.marketplaces`: a marketplace's
# name comes from its manifest, not its repo path, and what has to be declared
# is precisely the set the installed plugins resolve through.
check 'every plugin marketplace is declared in user settings' \
	"$(jq -r '.plugins[] | split("@")[1]' "$CONFIG" | sort -u | paste -sd, -)" \
	'node -e "const s=require(\"/home/agent/.claude/settings.json\"); console.log(Object.keys(s.extraKnownMarketplaces).sort().join(\",\"))"'

# Proves the skills actually landed on disk and are readable at uid 1000, not
# merely that the installer claimed success.
check 'superpowers skills are readable by the agent' \
	'brainstorming' \
	'ls /home/agent/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
