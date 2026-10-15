# Foundry runs from its official image only; no host install needed.
FOUNDRY_IMAGE ?= ghcr.io/foundry-rs/foundry:v1.7.1
DOCKER_FORGE  = docker run --rm -v "$(CURDIR)":/work -v "$(CURDIR)/.cache/svm":/home/foundry/.svm \
	-w /work/contracts --entrypoint forge $(FOUNDRY_IMAGE)

.PHONY: build test fmt fmt-check gas fixtures submodules abis relayer-test e2e-local e2e-down sepolia-setup sepolia-to-eth sepolia-to-gno

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

# Refreshes the ABIs the relayer embeds from the Foundry build.
abis: build
	for c in ICS26Router ICS20Transfer GnoLightClient IBCERC20; do \
		python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))['abi'], indent=1))" \
			contracts/out/$$c.sol/$$c.json > relayer/eth/abi/$$c.json; done

relayer-test:
	cd relayer && go test ./...

# gno.land -> anvil end to end: resets the local testnet, starts anvil, deploys, transfers, relays.
e2e-local: build
	./scripts/e2e-local.sh

e2e-down:
	-docker rm -f gno-eth-anvil
	-./testnet/down.sh

# Live Sepolia: needs a funded key in .env (see scripts/sepolia.sh).
sepolia-setup: build
	./scripts/sepolia.sh setup

sepolia-to-eth:
	./scripts/sepolia.sh to-eth

sepolia-to-gno:
	./scripts/sepolia.sh to-gno
