# Foundry runs from its official image only; no host install needed.
FOUNDRY_IMAGE ?= ghcr.io/foundry-rs/foundry:v1.7.1
DOCKER_FORGE  = docker run --rm -v "$(CURDIR)":/work -v "$(CURDIR)/.cache/svm":/home/foundry/.svm \
	-w /work/contracts --entrypoint forge $(FOUNDRY_IMAGE)

.PHONY: build test fmt fmt-check gas fixtures submodules

submodules:
	git submodule update --init --recursive

$(CURDIR)/.cache/svm:
	mkdir -p $@

build: | $(CURDIR)/.cache/svm
	$(DOCKER_FORGE) build

test: | $(CURDIR)/.cache/svm
	$(DOCKER_FORGE) test $(FORGE_ARGS)

gas: | $(CURDIR)/.cache/svm
	$(DOCKER_FORGE) test --gas-report $(FORGE_ARGS)

fmt: | $(CURDIR)/.cache/svm
	$(DOCKER_FORGE) fmt

fmt-check: | $(CURDIR)/.cache/svm
	$(DOCKER_FORGE) fmt --check

# Regenerates contracts/test/fixtures from the gno repository checked out next to this one.
fixtures:
	cd fixtures && go run ./cmd/genfixtures -out ../contracts/test/fixtures/gno.json
