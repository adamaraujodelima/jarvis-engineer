IMAGE   := jarvis-engineer:latest
TARBALL := $(CURDIR)/jarvis-engineer.tar
SANDBOX ?= jarvis-coder
KIT     ?= agents/coder

.PHONY: build template verify verify-image verify-kits verify-sandbox sandbox clean

## build: build the sandbox template image
build:
	docker build -t $(IMAGE) .

## template: load the built image into sbx as a reusable template
template: build verify-image
	docker image save $(IMAGE) -o $(TARBALL)
	sbx template load $(TARBALL)
	rm -f $(TARBALL)

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

## verify: static checks (image + kits). Use verify-sandbox for the live ones.
verify: verify-image verify-kits

verify-image:
	./scripts/verify-image.sh $(IMAGE)

verify-kits:
	./scripts/verify-kits.sh

## verify-sandbox: live checks against a running sandbox
verify-sandbox:
	./scripts/verify-sandbox.sh $(SANDBOX)

clean:
	rm -f $(TARBALL)
