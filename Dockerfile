FROM docker/sandbox-templates:claude-code

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

# Fail the build rather than ship an image whose tools the agent cannot reach.
RUN su agent -s /bin/sh -c 'ai-memory --version' \
 && su agent -s /bin/sh -c 'test -x /usr/local/share/ai-memory/hooks/claude-code/session-start.sh'

USER agent
