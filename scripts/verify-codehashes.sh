#!/usr/bin/env bash
# Verifies a deployment against a clean, reproducible build of this repository (ADR §6.12, T5): every deployed
# contract of the transfer app's and IBCAdmin's delegate graphs must equal the built runtime code of its source, the
# compiler's immutables aside, and every delegate address must be the one its holder records.
#
#   ETH_RPC_URL=...  DEPLOYMENTS_FILE=deployments/<chain>.json  scripts/verify-codehashes.sh
#
# Runs Foundry in Docker (the pinned image), from a clean build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOUNDRY_IMAGE="${FOUNDRY_IMAGE:-ghcr.io/foundry-rs/foundry:v1.7.1}"
: "${ETH_RPC_URL:?ETH_RPC_URL}" "${DEPLOYMENTS_FILE:?DEPLOYMENTS_FILE (relative to contracts/)}"
docker run --rm --network host -v "$ROOT":/work -v "$ROOT/.cache/svm":/home/foundry/.svm -w /work/contracts \
	-e DEPLOYMENTS_FILE --entrypoint sh "$FOUNDRY_IMAGE" -c \
	"forge build --force >/dev/null && forge script script/VerifyCodehashes.s.sol --rpc-url '$ETH_RPC_URL'"
