#!/bin/sh
#
# Install Claude Code plugins into the invoking user's ~/.claude.
#
# Usage: install-claude-plugins.sh
#   CLAUDE_MARKETPLACES  space-separated marketplace sources (repo, URL or path)
#   CLAUDE_PLUGINS       space-separated plugin@marketplace ids
#
# Run at image build time as the agent user, and available inside a running
# sandbox to add more plugins to that sandbox only.
#
# Both lists matter. The cache alone is not enough: a plugin whose marketplace
# is not declared in the user settings cannot be refreshed or re-resolved, and a
# plugin absent from `enabledPlugins` is on disk but never loaded. `plugin
# install` writes both, which is why this shells out to the CLI rather than
# assembling the JSON by hand.

set -eu

: "${CLAUDE_MARKETPLACES:=}"
: "${CLAUDE_PLUGINS:=}"

# Startup steps and `su` run with a narrower PATH than an interactive shell --
# it omits ~/.local/bin, where the claude CLI lives, so a bare `claude` exits
# 127. Prefer the stable symlink over the versioned binary it points at.
CLAUDE="$HOME/.local/bin/claude"
[ -x "$CLAUDE" ] || CLAUDE="$(command -v claude)"

# `claude-plugins-official` is bootstrapped by a running Claude Code session,
# not by the plugin CLI, so in a fresh ~/.claude it is unknown and installs from
# it fail with "not found in marketplace". Adding it explicitly is what makes a
# build-time install work; it resolves to the same public repo.
for marketplace in $CLAUDE_MARKETPLACES; do
	"$CLAUDE" plugin marketplace add "$marketplace"
done

# -y is required when stdin is not a TTY and the marketplace declares an install
# command; it is a no-op for the plain git-backed plugins.
for plugin in $CLAUDE_PLUGINS; do
	"$CLAUDE" plugin install "$plugin" -y
done

# A failed install still exits 0 in some paths, so confirm each id is actually
# registered rather than trusting the installer's own report.
for plugin in $CLAUDE_PLUGINS; do
	"$CLAUDE" plugin list --json | grep -q "\"id\": \"$plugin\"" || {
		echo "install-claude-plugins: $plugin is not registered" >&2
		exit 1
	}
done
