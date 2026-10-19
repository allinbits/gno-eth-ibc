#!/usr/bin/env bash
# Wrapper-level regression for scripts/verify-codehashes.sh: deploys the system on a throwaway anvil, then checks that
# the wrapper passes on the genuine deployment and fails when an extra verifier (CLIENTS) or voucher (VOUCHERS) is not
# a build of its source, which proves both lists reach the verifier inside Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOUNDRY_IMAGE="${FOUNDRY_IMAGE:-ghcr.io/foundry-rs/foundry:v1.7.1}"
PORT="${VERIFY_TEST_PORT:-8547}"
NAME="verify-wrapper-anvil-$$"
DEP="deployments/verify-wrapper-test.json"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -f "$ROOT/contracts/$DEP"; }
trap cleanup EXIT
docker run -d --rm --name "$NAME" --network host --entrypoint anvil "$FOUNDRY_IMAGE" \
	--host 0.0.0.0 --port "$PORT" --gas-limit 300000000 >/dev/null
sleep 3
export ETH_RPC_URL="http://127.0.0.1:$PORT"
# anvil's first development key (public, test only)
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
docker run --rm --network host -v "$ROOT":/work -v "$ROOT/.cache/svm":/home/foundry/.svm -w /work/contracts \
	-e DEPLOYER_PRIVATE_KEY="$KEY" -e DEPLOYMENTS_FILE="$DEP" --entrypoint forge "$FOUNDRY_IMAGE" \
	script script/DeployGnoIBC.s.sol --rpc-url "$ETH_RPC_URL" --broadcast --slow >/dev/null
export DEPLOYMENTS_FILE="$DEP"
field() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$ROOT/contracts/$DEP" "$1"; }
ROUTER=$(field ics26Router)
IMPL=$(field ics20Implementation)
fail=0
if "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then echo "ok   genuine deployment passes"; else echo "FAIL genuine deployment"; fail=1; fi
if CLIENTS="$ROUTER" "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then
	echo "FAIL a mismatching extra client passed (CLIENTS not forwarded?)"; fail=1
else echo "ok   a mismatching extra client fails"; fi
if VOUCHERS="$IMPL" "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then
	echo "FAIL a mismatching extra voucher passed (VOUCHERS not forwarded?)"; fail=1
else echo "ok   a mismatching extra voucher fails"; fi
# two builds: the checkout now differs from the deployed release (another release's controls), so the live check fails
# from it, while the candidate-only mode, which never rebuilds the live code, still runs
EVIDENCE="$ROOT/contracts/src/transfer/GnoICS20Evidence.sol"
cp "$EVIDENCE" "$EVIDENCE.orig"
python3 - "$EVIDENCE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().rstrip()
assert s.endswith("}")
open(p, "w").write(s[:-1] + "    function releaseB() external pure returns (uint256) {\n        return 2;\n    }\n}\n")
PY
if "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then echo "FAIL another release's checkout passed the live check"; fail=1
else echo "ok   another release's checkout fails the live check"; fi
if CANDIDATES_ONLY=true "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then echo "ok   candidate-only mode runs from another release"
else echo "FAIL candidate-only mode"; fail=1; fi
mv "$EVIDENCE.orig" "$EVIDENCE"
exit $fail
