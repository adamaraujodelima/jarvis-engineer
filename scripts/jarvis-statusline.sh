#!/bin/sh
#
# Render -- and register -- the Claude Code status line for a jarvis kit.
#
#   jarvis-statusline             read the status JSON on stdin, print one line
#   jarvis-statusline --install   point ~/.claude/settings.json at this script
#
# Both modes live in one installed file because a sandbox needs both and only
# what the image installs survives: `sbx create` recreates ~/.claude, so the
# registration has to re-run as a startup step in every kit, and the renderer it
# points at must sit outside $HOME.
#
# The role label is static per kit. It comes from $JARVIS_ROLE, else the first
# line of ~/.jarvis-role, which each kit ships in files/home/. It is deliberately
# NOT read from the spec's `environment.variables`: scripts/verify-kits.sh
# byte-compares that block across kits, so a per-kit value there reads as drift.

set -eu

SETTINGS="$HOME/.claude/settings.json"
SELF=/usr/local/bin/jarvis-statusline

if [ "${1:-}" = "--install" ]; then
	# Merged rather than written: sbx's own entries, ai-memory's hooks and the
	# restored plugin keys share this file, and this step runs after all three.
	node -e '
		const fs = require("fs");
		const path = require("path");
		const [settingsPath, command] = process.argv.slice(1);

		let settings = {};
		if (fs.existsSync(settingsPath)) {
			settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
		} else {
			fs.mkdirSync(path.dirname(settingsPath), {recursive: true});
		}

		settings.statusLine = {type: "command", command};

		fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
	' "$SETTINGS" "$SELF"
	exit 0
fi

ROLE="${JARVIS_ROLE:-}"
if [ -z "$ROLE" ] && [ -r "$HOME/.jarvis-role" ]; then
	ROLE="$(head -n1 "$HOME/.jarvis-role" | tr -d '\r')"
fi

# node ships in the base image, and the status payload is JSON: parsing it with
# sed would break on the first path containing a quote.
JARVIS_ROLE="$ROLE" node -e '
	const fs = require("fs");
	const path = require("path");
	const {execFileSync} = require("child_process");

	// A malformed or empty payload must still render a line: Claude Code shows
	// the script status output verbatim, so a crash here is what the user sees.
	let status = {};
	try {
		status = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
	} catch {
		status = {};
	}

	const dir = status.workspace?.current_dir || status.cwd || process.cwd();

	let branch = "";
	try {
		branch = execFileSync("git", ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"], {
			encoding: "utf8",
			stdio: ["ignore", "pipe", "ignore"],
		}).trim();
	} catch {
		// Not a work tree, or no commit yet -- the segment is simply dropped.
	}

	const parts = [
		process.env.JARVIS_ROLE || "AGENT",
		status.model?.display_name,
		path.basename(dir),
		branch,
	];

	console.log(parts.filter(Boolean).join(" | "));
'
