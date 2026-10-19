#!/usr/bin/env bash
# Verifies what runs on chain against a clean, reproducible build of this repository (ADR §6.12, T5): the transfer
# and router proxies' live implementations, the escrow and voucher beacons' implementations, IBCAdmin and its
# installed executor, each delegate graph complete, must equal the built runtime code of their sources (the
# compiler's immutables aside). Run it again for every pending kind 7 or kind 9 before it matures, naming the
# decision, the hash of the envelope gno.land sent, and the candidate it installs:
#
#   ETH_RPC_URL=...  DEPLOYMENTS_FILE=deployments/<chain>.json  scripts/verify-codehashes.sh
#   ETH_RPC_URL=...  DEPLOYMENTS_FILE=...  PENDING_SEQS=12,13  PENDING_HASHES=0x..,0x..  \
#       PENDING_CANDIDATES=0x..,0x..  scripts/verify-codehashes.sh
#   ETH_RPC_URL=...  DEPLOYMENTS_FILE=...  VOUCHERS=0x..,0x..  CLIENTS=0x..  scripts/verify-codehashes.sh
#       (further registered vouchers, enrolled or attested verifiers: a recovery proposal's lightClient)
#
# Runs Foundry in Docker (the pinned image), from a clean build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOUNDRY_IMAGE="${FOUNDRY_IMAGE:-ghcr.io/foundry-rs/foundry:v1.7.1}"
: "${ETH_RPC_URL:?ETH_RPC_URL}" "${DEPLOYMENTS_FILE:?DEPLOYMENTS_FILE (relative to contracts/)}"
docker run --rm --network host -v "$ROOT":/work -v "$ROOT/.cache/svm":/home/foundry/.svm -w /work/contracts \
	-e DEPLOYMENTS_FILE -e PENDING_SEQS -e PENDING_HASHES -e PENDING_CANDIDATES -e VOUCHERS -e CLIENTS \
	--entrypoint sh "$FOUNDRY_IMAGE" -c \
	"forge build --force >/dev/null && forge script script/VerifyCodehashes.s.sol --rpc-url '$ETH_RPC_URL'"
