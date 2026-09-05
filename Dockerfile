# The `-docker` flavour of the base template is the supported way to give an
# agent a working Docker Engine: it ships dockerd/containerd, puts the agent in
# the `docker` group, and carries the `com.docker.sandboxes.start-docker=true`
# label that makes sbx run the sandbox privileged and launch dockerd itself
# (logging to /var/log/dockerd.log) before the agent starts. The plain
# `claude-code` flavour has the docker CLI but no daemon, so every docker
# command fails with "dial unix /var/run/docker.sock: no such file".
#
# The daemon is nested inside the sandbox -- it is not the host's. Nothing here
# exposes the host socket, and images/containers the agent creates live and die
# with the sandbox.
FROM docker/sandbox-templates:claude-code-docker

USER root

# Pin the release so template rebuilds are reproducible. Bump deliberately.
ARG AI_MEMORY_VERSION=2.0.1

# mise is a build-time tool only: it resolves the correct release asset for the
# target architecture (these base images are amd64 + arm64) and verifies the
# published .sha256. Redirect it out of $HOME -- /root is mode 0700, so anything
# installed there is unreachable by the agent user the sandbox actually runs as.
ENV MISE_INSTALL_PATH=/usr/local/bin/mise \
    MISE_DATA_DIR=/opt/mise \
    MISE_CONFIG_DIR=/opt/mise \
    MISE_YES=1

RUN curl -fsSL https://mise.run/bash | sh

# Expose ai-memory on the image's existing PATH and drop its bundled hooks at
# the path `install-hooks --hooks-dir` already defaults to, so the kit's startup
# steps need no extra flags.
# The binary is copied rather than symlinked on purpose: `install-hooks` resolves
# its own executable through any symlink and writes that absolute path into
# ~/.claude/settings.json. Symlinking would bake the version-pinned mise path
# ("/opt/mise/installs/.../2.0.1/ai-memory") into the agent's hook config, which
# breaks the moment AI_MEMORY_VERSION is bumped.
RUN mise use -g "github:akitaonrails/ai-memory@${AI_MEMORY_VERSION}" \
 && src="$(mise where "github:akitaonrails/ai-memory@${AI_MEMORY_VERSION}")" \
 && install -m 0755 "$src/ai-memory" /usr/local/bin/ai-memory \
 && mkdir -p /usr/local/share/ai-memory \
 && cp -R "$src/hooks" /usr/local/share/ai-memory/hooks \
 && chmod -R a+rX /usr/local/share/ai-memory/hooks

RUN npm install -g @benborla29/mcp-server-mysql

# Bake the Claude Code plugins into the template. A sandbox gets a fresh
# ~/.claude, so plugins installed by hand are gone the next time one is created
# -- baking them is the only way the skills are there on first prompt.
#
# Override per project without editing this file:
#   docker build --build-arg CLAUDE_PLUGINS="superpowers@claude-plugins-official \
#     mattpocock-skills@mattpocock frontend-design@claude-plugins-official" .
# Marketplaces are cloned at build time, so anything added to CLAUDE_PLUGINS
# needs its marketplace in CLAUDE_MARKETPLACES too.
#
# There is no version pin to bump the way AI_MEMORY_VERSION is: the plugin CLI
# always installs the marketplace's current tip, and the result is then frozen
# in this layer. A plain rebuild keeps whatever was resolved the first time --
# use `docker build --no-cache-filter` on this stage to pick up new releases.
ARG CLAUDE_MARKETPLACES="anthropics/claude-plugins-official mattpocock/skills"
ARG CLAUDE_PLUGINS="superpowers@claude-plugins-official mattpocock-skills@mattpocock"

# Kept on PATH rather than deleted after the build: it is the same operation an
# agent needs to add a plugin to its own running sandbox.
COPY scripts/install-claude-plugins.sh /usr/local/bin/install-claude-plugins

# Runs as the agent, not root: `plugin install` records absolute installPaths in
# ~/.claude/plugins/installed_plugins.json, so installing as root would bake
# /root paths that uid 1000 cannot read -- the same trap mise fell into above.
# `su` alone does not set HOME, and $CLAUDE_* are root's build args, so both are
# passed explicitly.
RUN chmod 0755 /usr/local/bin/install-claude-plugins \
 && su agent -s /bin/sh -c "HOME=/home/agent \
      CLAUDE_MARKETPLACES='${CLAUDE_MARKETPLACES}' \
      CLAUDE_PLUGINS='${CLAUDE_PLUGINS}' \
      install-claude-plugins"

# Fail the build rather than ship an image whose tools the agent cannot reach.
RUN su agent -s /bin/sh -c 'ai-memory --version' \
 && su agent -s /bin/sh -c 'test -x /usr/local/share/ai-memory/hooks/claude-code/session-start.sh' \
 && command -v dockerd >/dev/null \
 && id -nG agent | grep -qw docker \
 && su agent -s /bin/sh -c 'HOME=/home/agent /home/agent/.local/bin/claude plugin list --json' \
      | grep -q '"enabled": true'

USER agent
