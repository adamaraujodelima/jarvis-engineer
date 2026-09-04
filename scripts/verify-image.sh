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

IMAGE="${1:-jarvis-engineer:latest}"
HOOKS_DIR=/usr/local/share/ai-memory/hooks

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
