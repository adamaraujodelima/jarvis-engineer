#!/usr/bin/env bash
#
# Kit-level acceptance checks.
#
# `sbx kit validate` only checks syntax -- it reports VALID for a kit whose
# `extends` target resolves to nothing. These cases assert the resolved artifact
# instead, and that the ai-memory block duplicated across kits has not drifted.
#
# Usage: scripts/verify-kits.sh

set -uo pipefail

cd "$(dirname "$0")/.."

# Discovered rather than listed: a hardcoded pair is how agents/planner and
# agents/reviewer ended up carrying the shared ai-memory block with nothing
# checking it. A new kit is covered the moment its spec lands.
KITS=()
for spec in agents/*/spec.yaml; do
	KITS+=("$(dirname "$spec")")
done

pass=0
fail=0

# spec_text <kit>
#
# The spec as one whitespace-normalised line. Assertions about command content
# have to survive a reformat: these specs are Prettier-formatted, and Prettier
# splits a long flow sequence across lines, which silently broke every check
# that matched the single-line form.
spec_text() {
	tr -s ' \n\t' ' ' <"$1/spec.yaml"
}

# check <name> <expected-substring> <actual>
check() {
	local name="$1" expected="$2" actual="$3"

	if [[ "$actual" == *"$expected"* ]]; then
		printf 'ok   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' \
			"$name" "$expected" "${actual:-<empty>}"
		fail=$((fail + 1))
	fi
}

printf '== kit acceptance ==\n'

for kit in "${KITS[@]}"; do
	inspected="$(sbx kit inspect "$kit" 2>&1)"

	check "$kit validates" 'VALID' "$(sbx kit validate "$kit" 2>&1)"

	# Guards the failure mode that left the investigator on the stock claude
	# image: a kit that resolves without the custom template silently loses
	# ai-memory entirely.
	check "$kit resolves to the custom template" \
		'jarvis-engineer:latest' "$inspected"

	check "$kit declares the memory volume + startup steps" \
		'8 startup' "$inspected"

	# host.docker.internal:3306 is accepted as a rule but never matches, because
	# enforcement normalises that name to localhost. Assert the rule that works.
	check "$kit allows mysql on the name enforcement matches" \
		'"localhost:3306"' "$(spec_text "$kit")"

	check "$kit tunnels mysql through the CONNECT proxy" \
		'PROXY:gateway.docker.internal:localhost:3306,proxyport=3128' \
		"$(spec_text "$kit")"

	check "$kit keeps mysql read-only" \
		'-e ALLOW_DELETE_OPERATION=false' "$(spec_text "$kit")"

	# The password must be inherited from the environment, never written into a
	# config file by -e.
	check "$kit does not register mysql credentials via -e" \
		'CLEAN' \
		"$(grep -qE '\-e MYSQL_(PASS|USER)=' "$kit/spec.yaml" && echo LEAKED || echo CLEAN)"

	check "$kit degrades when credentials are absent" \
		'skipping registration' "$(spec_text "$kit")"

	# Startup steps get a PATH without ~/.local/bin, so a bare `claude` exits
	# 127 -- and a non-zero startup step silently aborts all later steps.
	check "$kit invokes claude by absolute path" \
		'CLAUDE=/home/agent/.local/bin/claude' "$(spec_text "$kit")"

	check "$kit cannot abort the startup chain" \
		'CLEAN' \
		"$(awk '/Register the read-only MySQL/{found=1} END{exit 0}
		        {print}' "$kit/spec.yaml" >/dev/null;
		   grep -q 'exit 0' "$kit/spec.yaml" && echo CLEAN || echo RISK)"

	check "$kit gates the agent on server readiness" \
		'server not ready after 30s' "$(spec_text "$kit")"

	check "$kit runs the serve subcommand" \
		'"ai-memory", "serve", "--transport", "http", "--bind", "127.0.0.1:49374"' \
		"$(spec_text "$kit")"

	check "$kit backgrounds the server" 'background: true' "$(spec_text "$kit")"

	check "$kit chowns the volume to the agent uid" \
		'chown 1000:1000 /var/lib/ai-memory' "$(spec_text "$kit")"

	check "$kit points the store at the volume" \
		'AI_MEMORY_DATA_DIR: /var/lib/ai-memory' "$(spec_text "$kit")"
done

# The shared block is duplicated by necessity; assert the copies agree.
# Normalised the same way as spec_text: indentation and line breaks are the
# formatter's business, so only a real difference in content counts as drift.
shared_block() {
	sed -n '/^environment:/,$p' "$1/spec.yaml" |
		grep -vE '^\s*#|^\s*$|MYSQL_|IS_SANDBOX' |
		tr -s ' \n\t' ' '
}

reference="${KITS[0]}"
for kit in "${KITS[@]:1}"; do
	if [[ "$(shared_block "$reference")" == "$(shared_block "$kit")" ]]; then
		printf 'ok   %s shares the ai-memory block with %s\n' "$kit" "$reference"
		pass=$((pass + 1))
	else
		printf 'FAIL %s has drifted from %s\n' "$kit" "$reference"
		# Normalisation collapses the block onto one line, so diff it word by word
		# rather than emitting two unreadable walls of text.
		diff <(shared_block "$reference" | tr ' ' '\n') \
			<(shared_block "$kit" | tr ' ' '\n') | sed 's/^/     /'
		fail=$((fail + 1))
	fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
