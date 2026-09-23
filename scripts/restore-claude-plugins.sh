#!/bin/sh
#
# Re-apply the plugin entries the template baked into the agent's user settings.
#
# Usage: restore-claude-plugins [snapshot.json]
#
# `sbx create` writes ~/.claude/settings.json from scratch (permissions, model),
# which discards the file the image built. The plugin *cache* under
# ~/.claude/plugins does survive, so the loss is settings-only -- but a plugin
# absent from `enabledPlugins` is on disk and never loaded, and a marketplace
# absent from `extraKnownMarketplaces` cannot be re-resolved. Without this every
# baked plugin comes up disabled in a fresh sandbox, so it runs as a startup step
# in every kit.
#
# Merging rather than overwriting matters in both directions: sbx's own entries
# and ai-memory's hooks share this file, and re-running must not undo them.

set -eu

SNAPSHOT="${1:-/usr/local/share/jarvis-engineer/plugin-settings.json}"
SETTINGS="$HOME/.claude/settings.json"

[ -r "$SNAPSHOT" ] || {
	echo "restore-claude-plugins: cannot read $SNAPSHOT" >&2
	exit 1
}

# node ships in the base image. Hand-assembling the JSON with sed would corrupt
# a settings file whose other keys this script has no business understanding.
node -e '
	const fs = require("fs");
	const [snapshotPath, settingsPath] = process.argv.slice(1);
	const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));

	// A settings file is normal but not guaranteed: the startup step may run
	// before anything else has written one.
	let settings = {};
	if (fs.existsSync(settingsPath)) {
		settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
	} else {
		fs.mkdirSync(require("path").dirname(settingsPath), {recursive: true});
	}

	// Only the two plugin keys are touched, and only per entry: a plugin the
	// agent installed itself in this sandbox keeps its own state.
	for (const key of ["enabledPlugins", "extraKnownMarketplaces"]) {
		if (!snapshot[key]) continue;
		settings[key] = Object.assign({}, settings[key], snapshot[key]);
	}

	fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
' "$SNAPSHOT" "$SETTINGS"
