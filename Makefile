IMAGE       := jarvis-engineer:latest
CODEX_IMAGE := jarvis-engineer-codex:latest
TARBALL     := $(CURDIR)/jarvis-engineer.tar
CODEX_TARBALL := $(CURDIR)/jarvis-engineer-codex.tar
SANDBOX ?= jarvis-engineer
KIT     ?= agent
CODEX_SANDBOX ?= jarvis-engineer-codex
CODEX_KIT     ?= agent-codex

.PHONY: build build-codex template template-codex sync verify verify-sync verify-image verify-image-codex verify-kits verify-sandbox verify-sandbox-codex sandbox sandbox-codex clean

## build: build the sandbox template image
build:
	docker build -t $(IMAGE) .

## build-codex: build the Codex sandbox template image
build-codex:
	docker build -f Dockerfile.codex -t $(CODEX_IMAGE) .

## template: load the built image into sbx as a reusable template
template: build verify-image
	docker image save $(IMAGE) -o $(TARBALL)
	sbx template load $(TARBALL)
	rm -f $(TARBALL)

## template-codex: load the built Codex image into sbx as a reusable template
template-codex: build-codex verify-image-codex
	docker image save $(CODEX_IMAGE) -o $(CODEX_TARBALL)
	sbx template load $(CODEX_TARBALL)
	rm -f $(CODEX_TARBALL)

## sandbox: (re)create SANDBOX from KIT with credentials from .env
##
## --env-file is required: MYSQL_USER/MYSQL_PASS are read from the sandbox
## environment by the MySQL MCP server, and are never written into any config.
## A kind:sandbox kit registers under its spec `name:`, not its directory name,
## and that is the agent argument `sbx create` expects.
AGENT = $(shell awk '/^name:/ {print $$2; exit}' $(KIT)/spec.yaml)

sandbox:
	-sbx rm --force $(SANDBOX)
	sbx create --name $(SANDBOX) --env-file .env --kit $(KIT) $(AGENT) .
	./scripts/verify-sandbox.sh $(SANDBOX)

## sandbox-codex: (re)create CODEX_SANDBOX from CODEX_KIT, same .env rules
CODEX_AGENT = $(shell awk '/^name:/ {print $$2; exit}' $(CODEX_KIT)/spec.yaml)

sandbox-codex:
	-sbx rm --force $(CODEX_SANDBOX)
	sbx create --name $(CODEX_SANDBOX) --env-file .env --kit $(CODEX_KIT) $(CODEX_AGENT) .
	./scripts/verify-sandbox-codex.sh $(CODEX_SANDBOX)

## sync: regenerate the kit content of agent/ and agent-codex/ from shared/
sync:
	./scripts/sync-agents.sh

## verify: static checks (sync + both images + kits). Use verify-sandbox* for the live ones.
verify: verify-sync verify-image verify-image-codex verify-kits

## verify-sync: generator tests, then fail if the committed kit content drifted from shared/
verify-sync:
	./scripts/test-sync-agents.sh
	./scripts/sync-agents.sh --check

verify-image:
	./scripts/verify-image.sh $(IMAGE)

verify-image-codex:
	./scripts/verify-image-codex.sh $(CODEX_IMAGE)

verify-kits:
	./scripts/verify-kits.sh

## verify-sandbox: live checks against a running sandbox
verify-sandbox:
	./scripts/verify-sandbox.sh $(SANDBOX)

## verify-sandbox-codex: live checks against a running Codex sandbox
verify-sandbox-codex:
	./scripts/verify-sandbox-codex.sh $(CODEX_SANDBOX)

clean:
	rm -f $(TARBALL) $(CODEX_TARBALL)
