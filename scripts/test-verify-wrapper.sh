#!/usr/bin/env bash
# Wrapper-level regression for scripts/verify-codehashes.sh: deploys the system on a throwaway anvil, then checks that
# the wrapper passes on the genuine deployment and fails when an extra verifier (CLIENTS) or voucher (VOUCHERS) is not
# a build of its source, which proves both lists reach the verifier inside Docker; and that the per-component mode
# (COMPONENTS) verifies exactly the components of the checkout's release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOUNDRY_IMAGE="${FOUNDRY_IMAGE:-ghcr.io/foundry-rs/foundry:v1.7.1}"
PORT="${VERIFY_TEST_PORT:-8547}"
NAME="verify-wrapper-anvil-$$"
DEP="deployments/verify-wrapper-test.json"
cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	rm -f "$ROOT/contracts/$DEP"
	# a release-B source left by an interrupted run is restored
	for f in "$ROOT/contracts/src/transfer/GnoICS20Evidence.sol" "$ROOT/contracts/src/admin/IBCAdminExec.sol" \
		"$ROOT/contracts/src/admin/IBCAdminNative.sol"; do
		if [ -f "$f.orig" ]; then mv "$f.orig" "$f"; fi
	done
}
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
# a mixed deployment: from this other release's checkout, the components it did not change still verify, the one it
# changed (the transfer app) does not, and an unknown name is refused
if COMPONENTS=router,escrow,ibcerc20,admin,exec,launchClient,launchVoucher "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1
then echo "ok   per-component mode verifies the unchanged components"; else echo "FAIL per-component mode, unchanged components"; fail=1; fi
if COMPONENTS=transfer "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then
	echo "FAIL per-component mode passed a component of another release"; fail=1
else echo "ok   per-component mode fails the changed component"; fi
if COMPONENTS=nonesuch "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then echo "FAIL an unknown component passed"; fail=1
else echo "ok   an unknown component is refused"; fi
mv "$EVIDENCE.orig" "$EVIDENCE"
# back on the deployed release's checkout, the changed component verifies alone
if COMPONENTS=transfer "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then echo "ok   per-component mode on its own release"
else echo "FAIL per-component mode on its own release"; fail=1; fi

# A real mixed deployment. Release B changes the transfer graph, the executor and IBCAdmin's own code
# (IBCAdminNative, which IBCAdmin deploys in its constructor); only B's transfer graph is
# installed (kind 7's effect, applied here by IBCAdmin itself, impersonated on the throwaway anvil: the proxy's
# upgrade is restricted to the AccessManager's admin, IBCAdmin), so the chain runs B's transfer app with release A's
# executor and everything else. The manifest then says: transfer from B, every other component from A.
EXEC_SRC="$ROOT/contracts/src/admin/IBCAdminExec.sol"
NATIVE_SRC="$ROOT/contracts/src/admin/IBCAdminNative.sol"
releaseB() {
	for f in "$EVIDENCE" "$EXEC_SRC" "$NATIVE_SRC"; do cp "$f" "$f.orig"; done
	python3 - "$EVIDENCE" "$EXEC_SRC" "$NATIVE_SRC" <<'PY'
import sys
for p in sys.argv[1:]:
    s = open(p).read().rstrip()
    assert s.endswith("}")
    open(p, "w").write(s[:-1] + "    function releaseB() external pure returns (uint256) {\n        return 2;\n    }\n}\n")
PY
}
releaseA() { for f in "$EVIDENCE" "$EXEC_SRC" "$NATIVE_SRC"; do mv "$f.orig" "$f"; done; }
dock() {
	docker run --rm --network host -v "$ROOT":/work -v "$ROOT/.cache/svm":/home/foundry/.svm -w /work/contracts \
		--entrypoint sh "$FOUNDRY_IMAGE" -c "$1"
}
create() { # <artifact> [<constructor arg>]: the deployed address
	dock "forge create --broadcast --rpc-url '$ETH_RPC_URL' --private-key '$KEY' '$1' ${2:+--constructor-args $2}" |
		awk '/Deployed to:/ {print $3}'
}
ADMIN=$(field ibcAdmin)
ICS20=$(field ics20Transfer)
releaseB
EV=$(create src/transfer/GnoICS20Evidence.sol:GnoICS20Evidence)
RC=$(create src/transfer/GnoICS20Reconcile.sol:GnoICS20Reconcile "$EV")
CT=$(create src/transfer/GnoICS20Controls.sol:GnoICS20Controls "$RC")
IMPL_B=$(create src/GnoICS20Transfer.sol:GnoICS20Transfer "$CT")
dock "cast rpc --rpc-url '$ETH_RPC_URL' anvil_impersonateAccount $ADMIN >/dev/null &&
	cast rpc --rpc-url '$ETH_RPC_URL' anvil_setBalance $ADMIN 0x8ac7230489e80000 >/dev/null &&
	cast send --rpc-url '$ETH_RPC_URL' --unlocked --from $ADMIN $ICS20 'upgradeToAndCall(address,bytes)' $IMPL_B 0x >/dev/null"
NOW=$(dock "cast implementation --rpc-url '$ETH_RPC_URL' $ICS20" | tr 'A-F' 'a-f')
if [ -n "$IMPL_B" ] && [ "$NOW" = "$(echo "$IMPL_B" | tr 'A-F' 'a-f')" ]; then echo "ok   mixed deployment: release B's transfer graph installed"
else echo "FAIL mixed deployment: the upgrade to release B ($IMPL_B, live $NOW)"; fail=1; fi
A_PARTS=router,escrow,ibcerc20,admin,exec,launchClient,launchVoucher
# from release B's checkout: its own component passes, release A's executor does not, nor does the whole system
if COMPONENTS=transfer "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then echo "ok   mixed: transfer verifies from release B"
else echo "FAIL mixed: transfer from release B"; fail=1; fi
if COMPONENTS=exec "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then
	echo "FAIL mixed: release A's executor passed from release B (a wrong assignment)"; fail=1
else echo "ok   mixed: a wrong assignment (exec to release B) fails"; fi
if COMPONENTS=admin "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then
	echo "FAIL mixed: IBCAdmin (with its IBCAdminNative) passed from release B (a wrong assignment)"; fail=1
else echo "ok   mixed: a wrong assignment (admin to release B) fails"; fi
if "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then echo "FAIL mixed: the whole system passed from release B"; fail=1
else echo "ok   mixed: the whole system fails from release B"; fi
releaseA
# from release A's checkout: its components pass, B's transfer graph does not, nor does the whole system
if COMPONENTS="$A_PARTS" "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then echo "ok   mixed: release A's components verify from release A"
else echo "FAIL mixed: release A's components from release A"; fail=1; fi
if COMPONENTS=transfer "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then
	echo "FAIL mixed: release B's transfer graph passed from release A (a wrong assignment)"; fail=1
else echo "ok   mixed: a wrong assignment (transfer to release A) fails"; fi
if "$ROOT/scripts/verify-codehashes.sh" >/dev/null 2>&1; then echo "FAIL mixed: the whole system passed from release A"; fail=1
else echo "ok   mixed: the whole system fails from release A"; fi
exit $fail
