#!/usr/bin/env bash
#
# Live acceptance checks against a running sandbox.
#
# Kit and image checks cannot prove the MySQL path works: raw TCP egress is
# blocked in a sandbox, so the tunnel is only observable at runtime. These cases
# assert the output of real queries and a real MCP health check.
#
# Usage: scripts/verify-sandbox.sh <sandbox-name>

set -uo pipefail

SANDBOX="${1:-}"
if [[ -z "$SANDBOX" ]]; then
	printf 'usage: %s <sandbox-name>\n\n' "$0" >&2
	sbx ls >&2
	exit 2
fi

pass=0
fail=0

# check <name> <expected-substring> <remote-shell-command>
check() {
	local name="$1" expected="$2" actual

	actual="$(sbx exec "$SANDBOX" -- sh -c "$3" 2>&1)"

	if [[ "$actual" == *"$expected"* ]]; then
		printf 'ok   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' \
			"$name" "$expected" "${actual:-<empty>}"
		fail=$((fail + 1))
	fi
}

printf '== live sandbox acceptance: %s ==\n' "$SANDBOX"

# Startup steps complete asynchronously after `sbx create` returns, so poll for
# the last one rather than racing it.
printf 'waiting for startup steps to finish'
sbx exec "$SANDBOX" -- sh -c '
	for i in $(seq 1 60); do
		/home/agent/.local/bin/claude mcp list 2>/dev/null | grep -qE "^mysql:" && exit 0
		sleep 2
	done
	exit 1' >/dev/null 2>&1 && printf ' done\n\n' || printf ' TIMED OUT\n\n'

# --- ai-memory ----------------------------------------------------------
check 'ai-memory MCP server answers a handshake' \
	'"serverInfo":{"name":"ai-memory"' \
	'curl -s --max-time 10 http://127.0.0.1:49374/mcp -X POST -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"v\",\"version\":\"0\"}}}"'

check 'memory store is on the persistent volume' \
	'/var/lib/ai-memory' \
	'echo "$AI_MEMORY_DATA_DIR"'

check 'memory volume is writable by the agent' \
	'agent:agent' \
	'stat -c %U:%G /var/lib/ai-memory'

# --- mysql --------------------------------------------------------------
check 'mysql tunnel is listening on loopback' \
	'TUNNEL_UP' \
	'socat -u /dev/null TCP:127.0.0.1:3306,connect-timeout=5 >/dev/null 2>&1 && echo TUNNEL_UP'

# A MySQL server greets on connect; anything else means we reached a stub.
check 'tunnel reaches a real MySQL server' \
	'GREETING_OK' \
	'node -e "
	  const net=require(\"net\");
	  const s=net.connect(3306,\"127.0.0.1\");
	  s.setTimeout(8000);
	  s.on(\"data\",d=>{console.log(/[0-9]+\.[0-9]+\.[0-9]+/.test(d.toString(\"latin1\"))?\"GREETING_OK\":\"NO_VERSION\");s.end();});
	  s.on(\"timeout\",()=>{console.log(\"TIMEOUT\");s.destroy();});
	  s.on(\"error\",e=>console.log(\"ERROR\",e.code));
	"'

check 'mysql MCP server is registered and connects' \
	'mysql' \
	'claude mcp list 2>&1 | grep -E "^mysql:"'

check 'both MCP servers report connected' \
	'2' \
	'claude mcp list 2>&1 | grep -cE "^(mysql|ai-memory):.*Connected"'

check 'mysql credentials are absent from the agent config' \
	'CLEAN' \
	'grep -qE "MYSQL_(PASS|USER)" ~/.claude.json && echo LEAKED || echo CLEAN'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
