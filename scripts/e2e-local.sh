#!/usr/bin/env bash
# End-to-end gno.land -> EVM relaying on a local machine:
#   1. a fresh 3-validator secp256k1 gno.land testnet (testnet/up.sh -reset)
#   2. anvil in Docker
#   3. a placeholder Ethereum client on gno, then IBC (ICS26Router, ICS20Transfer,
#      GnoLightClient) deployed on anvil with forge, and the counterparties linked
#   4. an ICS20 transfer of ugnot from gno to an anvil address
#   5. the relayer updates GnoLightClient, proves the packet commitment and
#      calls recvPacket; the ack must be committed on anvil and the receiver
#      must hold the IBCERC20 voucher.
# The ack is not relayed back to gno: that needs gno's Ethereum light client
# to follow a beacon chain, which anvil does not have.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOUNDRY_IMAGE="${FOUNDRY_IMAGE:-ghcr.io/foundry-rs/foundry:v1.7.1}"
NET="${E2E_DOCKER_NETWORK:-gno-eth-e2e}"
ANVIL="${E2E_ANVIL_CONTAINER:-gno-eth-anvil}"
ANVIL_PORT="${ANVIL_PORT:-8545}"
GNO_RPC="${GNO_RPC:-http://127.0.0.1:26657}"
GNO_CHAIN_ID="${GNO_CHAIN_ID:-gno-eth-dev}"
WORK="$ROOT/.cache/e2e"
DEPLOY_DIR="$ROOT/contracts/deployments"
BIN="$ROOT/.cache/bin"

# Local, publicly known development keys only: anvil's first two accounts and
# the testnet's genesis-funded test1 key. Override through the environment.
export DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
export ETH_PRIVATE_KEY="${ETH_PRIVATE_KEY:-$DEPLOYER_PRIVATE_KEY}"
export GNO_MNEMONIC="${GNO_MNEMONIC:-source bonus chronic canvas draft south burst lottery vacant surface solve popular case indicate oppose farm nothing bullet exhibit title speed wink action roast}"
RECEIVER="${E2E_RECEIVER:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"
AMOUNT="${E2E_AMOUNT:-1000000}"
export ETH_RPC_URL="http://127.0.0.1:$ANVIL_PORT"

step() { printf '\n==> %s\n' "$*"; }
json() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))$2)" "$1"; }
rpc_height() { curl -sf "$GNO_RPC/status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["sync_info"]["latest_block_height"])'; }

mkdir -p "$WORK" "$DEPLOY_DIR" "$BIN" "$ROOT/.cache/svm"

step "building the relayer"
(cd "$ROOT/relayer" && go build -o "$BIN/relayer" ./cmd/relayer 2>&1 | grep -Ev 'warning|note:|^#|mdbx|^ld:' || true)
RELAYER="$BIN/relayer"
[[ -x "$RELAYER" ]] || { echo "relayer build failed" >&2; exit 1; }

step "starting a fresh gno.land testnet"
"$ROOT/testnet/up.sh" -reset
for _ in $(seq 1 120); do
	h=$(rpc_height 2>/dev/null || echo 0)
	[[ "$h" -ge 3 ]] && break
	sleep 1
done
[[ "$(rpc_height)" -ge 3 ]] || { echo "gno testnet did not start" >&2; exit 1; }
echo "gno at height $(rpc_height)"

step "starting anvil"
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker rm -f "$ANVIL" >/dev/null 2>&1 || true
docker run -d --name "$ANVIL" --network "$NET" -p "$ANVIL_PORT:8545" --entrypoint anvil "$FOUNDRY_IMAGE" \
	--host 0.0.0.0 --chain-id 31337 >/dev/null
for _ in $(seq 1 60); do
	curl -sf -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}' "$ETH_RPC_URL" >/dev/null && break
	sleep 1
done

step "creating the gno-side Ethereum client (placeholder, never updated)"
"$RELAYER" gno-create-eth-client -gno-rpc "$GNO_RPC" -evm-chain-id 31337 -out "$WORK/gno-client.json"
GNO_CLIENT=$(json "$WORK/gno-client.json" '["clientId"]')

step "trusting the latest gno header"
"$RELAYER" trust -gno-rpc "$GNO_RPC" -out "$DEPLOY_DIR/trust.json"

step "deploying IBC on anvil"
docker run --rm --network "$NET" -v "$ROOT":/work -v "$ROOT/.cache/svm":/home/foundry/.svm -w /work/contracts \
	-e DEPLOYER_PRIVATE_KEY -e GNO_TRUST_FILE=deployments/trust.json -e GNO_COUNTERPARTY_CLIENT_ID="$GNO_CLIENT" \
	-e DEPLOYMENTS_FILE=deployments/local.json \
	--entrypoint forge "$FOUNDRY_IMAGE" script script/DeployGnoIBC.s.sol --rpc-url "http://$ANVIL:8545" --broadcast \
	2>&1 | grep -E 'ONCHAIN EXECUTION|Error|error|revert' || true
DEP="$DEPLOY_DIR/local.json"
[[ -f "$DEP" ]] || { echo "deployment failed" >&2; exit 1; }
cat "$DEP"
ETH_CLIENT=$(json "$DEP" '["clientId"]')

step "registering $ETH_CLIENT as counterparty of $GNO_CLIENT on gno"
"$RELAYER" gno-register-counterparty -gno-rpc "$GNO_RPC" -client "$GNO_CLIENT" -counterparty "$ETH_CLIENT"

step "sending $AMOUNT ugnot from gno to $RECEIVER"
FROM=$(rpc_height)
TIMEOUT=$(( $(date +%s) + 3600 ))
echo "" | "$ROOT/testnet/.data/bin/gnokey" maketx call \
	-home "$ROOT/testnet/.data/gnokey" -insecure-password-stdin \
	-pkgpath gno.land/r/aib/ibc/apps/transfer -func Transfer \
	-args "$GNO_CLIENT" -args "$RECEIVER" -args ugnot -args "$AMOUNT" -args "$TIMEOUT" -args "" \
	-send "${AMOUNT}ugnot" -gas-fee 10000000ugnot -gas-wanted 150000000 \
	-broadcast -chainid "$GNO_CHAIN_ID" -remote "$GNO_RPC" test1 | tee "$WORK/transfer.txt"
grep -q "OK!" "$WORK/transfer.txt"

step "relaying gno -> anvil"
"$RELAYER" relay -gno-rpc "$GNO_RPC" -eth-rpc "$ETH_RPC_URL" -deployment "$DEP" -gno-client "$GNO_CLIENT" \
	-from "$FROM" -out "$WORK/relay.json"
cat "$WORK/relay.json"
[[ "$(json "$WORK/relay.json" '.__len__()')" -ge 1 ]] || { echo "no packet relayed" >&2; exit 1; }

step "checking the receiver's voucher balance"
"$RELAYER" erc20-balance -eth-rpc "$ETH_RPC_URL" -deployment "$DEP" -denom "transfer/$ETH_CLIENT/ugnot" \
	-owner "$RECEIVER" | tee "$WORK/balance.json"
BAL=$(json "$WORK/balance.json" '["balance"]')
if [[ "$BAL" != "$AMOUNT" ]]; then
	echo "FAIL: receiver holds $BAL, want $AMOUNT" >&2
	exit 1
fi
echo
echo "PASS: $AMOUNT ugnot relayed from gno ($GNO_CLIENT) to anvil ($ETH_CLIENT); ack committed on anvil; receiver balance $BAL"
