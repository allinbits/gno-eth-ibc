#!/usr/bin/env bash
# Starts a local gno.land testnet of three validators that sign with
# secp256k1, with the gno-realms IBC packages (and the Ethereum light client)
# deployed at genesis. State lives in testnet/.data; `down.sh` stops it and
# `up.sh -reset` starts from a fresh genesis.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GNO="${GNO:-$HERE/../../gno}"
GNO_REALMS="${GNO_REALMS:-$HERE/../../gno-realms}"
DATA="${DATA:-$HERE/.data}"
BIN="$DATA/bin"
CHAIN_ID="${CHAIN_ID:-gno-eth-dev}"
NODES=3

if [[ "${1:-}" == "-reset" ]]; then
	"$HERE/down.sh" || true
	rm -rf "$DATA"
fi
mkdir -p "$BIN"

build() {
	echo "building $1"
	(cd "$GNO/$2" && go build -o "$BIN/$1" . 2>&1 | grep -Ev 'warning|note:|mdbx|^ld:|^#' || true)
	[[ -x "$BIN/$1" ]] || { echo "failed to build $1" >&2; exit 1; }
}
[[ -x "$BIN/gnoland" ]] || build gnoland gno.land/cmd/gnoland
[[ -x "$BIN/gnokey" ]] || build gnokey gno.land/cmd/gnokey
[[ -x "$BIN/gnogenesis" ]] || build gnogenesis contribs/gnogenesis

# PORT_OFFSET shifts every port, to run a second testnet next to the first
# (with its own DATA directory).
PORT_OFFSET="${PORT_OFFSET:-0}"
rpc_port() { echo $((26657 + PORT_OFFSET + 10 * $1)); }
p2p_port() { echo $((26656 + PORT_OFFSET + 10 * $1)); }

if [[ ! -f "$DATA/genesis.json" ]]; then
	echo "generating genesis"
	"$BIN/gnogenesis" generate -chain-id "$CHAIN_ID" -output-path "$DATA/genesis.json" >/dev/null
	"$BIN/gnogenesis" balances add -genesis-path "$DATA/genesis.json" \
		-balance-sheet "$GNO/gno.land/genesis/genesis_balances.txt" >/dev/null

	python3 - "$DATA/genesis.json" <<'PY'
import json, sys
p = sys.argv[1]
g = json.load(open(p))
g["validators"] = []
# Ethereum verifies this chain's commits with ecrecover: only secp256k1
# consensus keys are allowed.
g["consensus_params"]["Validator"] = {"PubKeyTypeURLs": ["/tm.PubKeySecp256k1"]}
json.dump(g, open(p, "w"), indent=2)
PY

	for i in $(seq 0 $((NODES - 1))); do
		node="$DATA/node$i"
		"$BIN/gnoland" secrets init -data-dir "$node/secrets" >/dev/null
		"$BIN/gnoland" config init -config-path "$node/config/config.toml" >/dev/null
		pub=$("$BIN/gnoland" secrets get validator_key.pub_key -data-dir "$node/secrets" -raw)
		addr=$("$BIN/gnoland" secrets get validator_key.address -data-dir "$node/secrets" -raw)
		"$BIN/gnogenesis" validator add -genesis-path "$DATA/genesis.json" \
			-name "val$i" -address "$addr" -pub-key "$pub" -power 10 >/dev/null
	done

	# Deploy gno-realms at genesis with the funded test1 key.
	export GNOHOME="$DATA/gnokey"
	mnemonic="source bonus chronic canvas draft south burst lottery vacant surface solve popular case indicate oppose farm nothing bullet exhibit title speed wink action roast"
	printf '%s\n\n' "$mnemonic" | "$BIN/gnokey" add test1 --recover --insecure-password-stdin --home "$GNOHOME" >/dev/null 2>&1 || true
	# gnogenesis sorts each directory's packages on its own, so the examples
	# and gno-realms are staged in one tree for dependencies to resolve across
	# both.
	echo "adding the examples and gno-realms packages"
	pkgs="$DATA/pkgs"
	rm -rf "$pkgs" && mkdir -p "$pkgs"
	cp -R "$GNO/examples" "$pkgs/examples"
	cp -R "$GNO_REALMS/gno.land" "$pkgs/gno-realms"
	# Tests and test helpers are not needed on chain, and the package sorter
	# follows test imports, which cycle through the helpers.
	find "$pkgs/gno-realms" -type d \( -name testing -o -name filetests \) -prune -exec rm -rf {} +
	find "$pkgs/gno-realms" -name '*_test.gno' -delete
	echo "" | "$BIN/gnogenesis" txs add packages -genesis-path "$DATA/genesis.json" \
		-gno-home "$GNOHOME" -key-name test1 -insecure-password-stdin "$pkgs" | tail -1
fi

# Node configs: distinct ports, every node peers with the others.
peers=()
for i in $(seq 0 $((NODES - 1))); do
	id=$("$BIN/gnoland" secrets get node_id.id -data-dir "$DATA/node$i/secrets" -raw)
	peers+=("$id@127.0.0.1:$(p2p_port "$i")")
done
for i in $(seq 0 $((NODES - 1))); do
	cfg="$DATA/node$i/config/config.toml"
	set_cfg() { "$BIN/gnoland" config set -config-path "$cfg" "$1" "$2" >/dev/null; }
	set_cfg rpc.laddr "tcp://0.0.0.0:$(rpc_port "$i")"
	set_cfg p2p.laddr "tcp://0.0.0.0:$(p2p_port "$i")"
	others=$(printf '%s\n' "${peers[@]}" | grep -v "^${peers[$i]%%@*}@" | paste -sd, -)
	set_cfg p2p.persistent_peers "$others"
	set_cfg consensus.timeout_commit 1s
	set_cfg moniker "val$i"
done

for i in $(seq 0 $((NODES - 1))); do
	node="$DATA/node$i"
	[[ -f "$node/pid" ]] && kill -0 "$(cat "$node/pid")" 2>/dev/null && continue
	"$BIN/gnoland" start -gnoroot-dir "$GNO" -data-dir "$node" -genesis "$DATA/genesis.json" \
		-skip-genesis-sig-verification -log-level info >"$node/node.log" 2>&1 &
	echo $! >"$node/pid"
	echo "node$i: rpc http://127.0.0.1:$(rpc_port "$i") (pid $!)"
done
