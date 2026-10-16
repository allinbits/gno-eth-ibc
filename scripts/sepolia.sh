#!/usr/bin/env bash
# Links the local gno.land testnet (testnet/up.sh) with Ethereum Sepolia and
# relays an ICS20 round trip:
#
#   setup   fresh testnet, trust its header, deploy IBC + GnoLightClient on
#           Sepolia, create gno's Ethereum client (ethereum-1) from a beacon
#           bootstrap and link the counterparties
#   to-eth  send ugnot from gno to an Ethereum address, relay it, and relay
#           Sepolia's acknowledgement back to gno once finalized
#   to-gno  send the vouchers back from Sepolia to gno, relay them once
#           finalized, and relay gno's acknowledgement to Sepolia
#
# Needs .env with DEPLOYER_PRIVATE_KEY / ETH_PRIVATE_KEY (a funded Sepolia
# key). Ethereum -> gno proofs are taken at the finalized block, which most
# public RPCs cannot serve; PROOF_RPC must keep that much state history.
# Each relay to gno waits for Sepolia finality (about 13 to 15 minutes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
set -a
# shellcheck disable=SC1091
. ./.env
set +a

FOUNDRY_IMAGE="${FOUNDRY_IMAGE:-ghcr.io/foundry-rs/foundry:v1.7.1}"
ETH_RPC_URL="${ETH_RPC_URL:-https://rpc.sepolia.ethpandaops.io}"
PROOF_RPC="${PROOF_RPC:-https://rpc.sepolia.ethpandaops.io}"
BEACON_URL="${BEACON_URL:-https://lodestar-sepolia.chainsafe.io}"
GNO_RPC="${GNO_RPC:-http://127.0.0.1:26657}"
GNO_CLIENT="${GNO_CLIENT:-ethereum-1}"
DEP="contracts/deployments/sepolia.json"
export ETH_RPC_URL BEACON_URL
export GNO_MNEMONIC="${GNO_MNEMONIC:-source bonus chronic canvas draft south burst lottery vacant surface solve popular case indicate oppose farm nothing bullet exhibit title speed wink action roast}"
GNO_RECEIVER="${GNO_RECEIVER:-g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5}" # test1
ETH_RECEIVER="${ETH_RECEIVER:-$DEPLOYER_ADDRESS}"
AMOUNT="${AMOUNT:-1000000}"
RELAYER=.cache/bin/relayer
GNOKEY=testnet/.data/bin/gnokey

step() { printf '\n==> %s\n' "$*"; }
gno_height() { curl -sf "$GNO_RPC/status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["sync_info"]["latest_block_height"])'; }

build() {
	mkdir -p .cache/bin .cache/svm
	(cd relayer && go build -o "../$RELAYER" ./cmd/relayer 2>&1 | grep -Ev 'warning|note:|^#|mdbx|^ld:' || true)
}

setup() {
	step "fresh gno.land testnet"
	testnet/up.sh -reset
	until [[ "$(gno_height 2>/dev/null || echo 0)" -ge 3 ]]; do sleep 2; done

	step "trusting the latest gno header"
	"$RELAYER" trust -gno-rpc "$GNO_RPC" -out contracts/deployments/sepolia-trust.json

	step "deploying IBC on Sepolia"
	# Sepolia's repriced gas (Glamsterdam) defeats forge's local simulation:
	# take each estimate from the node instead.
	deploy() {
		local out="$1"
		shift
		docker run --rm -v "$ROOT":/work -v "$ROOT/.cache/svm":/home/foundry/.svm -w /work/contracts \
			-e DEPLOYER_PRIVATE_KEY -e GNO_TRUST_FILE=deployments/sepolia-trust.json \
			-e GNO_COUNTERPARTY_CLIENT_ID="$GNO_CLIENT" -e DEPLOYMENTS_FILE="$out" \
			--entrypoint forge "$FOUNDRY_IMAGE" script script/DeployGnoIBC.s.sol --rpc-url "$ETH_RPC_URL" \
			--broadcast --slow --skip-simulation --gas-estimate-multiplier 130 "$@"
	}
	# Load-balanced RPCs can report a stale nonce right after a receipt, which
	# makes forge abort the broadcast; resume it from the transactions sent.
	# A resumed run simulates the script again from the account's new nonce, so
	# the addresses it computes are not the deployed ones: keep the first run's.
	if ! deploy deployments/sepolia.json; then
		for i in 1 2 3 4 5; do
			step "a lagging RPC node interrupted the broadcast; resuming it ($i)"
			sleep 12
			deploy deployments/.sepolia-resumed.json --resume && break
			[[ $i == 5 ]] && exit 1
		done
	fi
	cat "$DEP"
	router=$(python3 -c "import json; print(json.load(open('$DEP'))['ics26Router'])")
	code=$(curl -sf -X POST -H 'content-type: application/json' "$ETH_RPC_URL" \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$router\",\"latest\"]}")
	if [[ "$code" == *'"result":"0x"'* || -z "$code" ]]; then
		echo "no contract at the deployed router $router" >&2
		exit 1
	fi

	step "creating gno's Ethereum client from a beacon bootstrap"
	"$RELAYER" gno-create-eth-client-live -gno-rpc "$GNO_RPC" -deployment "$DEP"
	"$RELAYER" gno-update-eth-client -gno-rpc "$GNO_RPC" -deployment "$DEP"
}

to_eth() {
	step "sending $AMOUNT ugnot from gno to $ETH_RECEIVER"
	FROM=$(gno_height)
	echo "" | "$GNOKEY" maketx call -home testnet/.data/gnokey -insecure-password-stdin \
		-pkgpath gno.land/r/aib/ibc/apps/transfer -func Transfer \
		-args "$GNO_CLIENT" -args "$ETH_RECEIVER" -args ugnot -args "$AMOUNT" \
		-args "$(( $(date +%s) + 7200 ))" -args "" \
		-send "${AMOUNT}ugnot" -gas-fee 10000000ugnot -gas-wanted 150000000 \
		-broadcast -chainid gno-eth-dev -remote "$GNO_RPC" test1

	step "relaying to Sepolia, then the acknowledgement back to gno"
	"$RELAYER" relay -gno-rpc "$GNO_RPC" -eth-rpc "$ETH_RPC_URL" -proof-rpc "$PROOF_RPC" -beacon "$BEACON_URL" \
		-deployment "$DEP" -gno-client "$GNO_CLIENT" -from "$FROM" -to "$(gno_height)"
}

to_gno() {
	step "sending $AMOUNT vouchers from Sepolia back to $GNO_RECEIVER"
	OUT=$("$RELAYER" eth-send-transfer -deployment "$DEP" -denom "transfer/$(python3 -c "import json; print(json.load(open('$DEP'))['clientId'])")/ugnot" \
		-amount "$AMOUNT" -receiver "$GNO_RECEIVER" -timeout 3h 2>&1 | tee /dev/stderr)
	BLOCK=$(sed -n 's/.* block=\([0-9]*\).*/\1/p' <<<"$OUT" | tail -1)

	step "relaying to gno once Sepolia finalizes block $BLOCK, then the acknowledgement to Sepolia"
	GNO_FROM=$(gno_height)
	"$RELAYER" relay-eth -gno-rpc "$GNO_RPC" -eth-rpc "$ETH_RPC_URL" -proof-rpc "$PROOF_RPC" -beacon "$BEACON_URL" \
		-deployment "$DEP" -gno-client "$GNO_CLIENT" -from "$BLOCK" -to "$BLOCK"
	# Acks relay-eth could not deliver (an earlier run, async acks) are picked up here.
	"$RELAYER" relay-gno-acks -gno-rpc "$GNO_RPC" -eth-rpc "$ETH_RPC_URL" -deployment "$DEP" \
		-gno-client "$GNO_CLIENT" -from "$GNO_FROM"
}

build
case "${1:-all}" in
setup) setup ;;
to-eth) to_eth ;;
to-gno) to_gno ;;
all) setup; to_eth; to_gno ;;
*) echo "usage: $0 [setup|to-eth|to-gno|all]" >&2; exit 2 ;;
esac
