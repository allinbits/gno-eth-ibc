// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Candidate code that writes state whenever it is asked anything, and answers what a probe would want only
/// if the write went through: under a STATICCALL every probe of it fails.
contract WritingCandidate {
    uint256 public writes;
    address internal immutable router;
    address internal immutable accessManager;
    address internal immutable ics20;
    address internal immutable target; // a contract it tries to act on with the caller's authority

    constructor(address router_, address accessManager_, address ics20_, address target_) {
        (router, accessManager, ics20, target) = (router_, accessManager_, ics20_, target_);
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        writes++; // reverts under a STATICCALL
        // and a state-changing call into the system (it would run as this candidate, never as its caller)
        (bool ok,) = target.call(abi.encodeWithSignature("drain()"));
        ok;
        if (data.length >= 4 && bytes4(data) == bytes4(keccak256("bindings()"))) {
            return abi.encode(router, accessManager, ics20);
        }
        return abi.encode(uint256(1), uint256(1));
    }
}

/// @notice Round 11, the gno.land P1's analogue: every call IBCAdmin, its executor, its checks and the transfer app
/// make to candidate code before installing it is a STATICCALL. A candidate whose probes write is refused, and its
/// writes never happen: a kind 6 verifier, a recovery proposal's client, a kind 9 executor, a kind 7 implementation.
contract CandidateStaticTest is ControlsFixture {
    function _recovery() internal pure override returns (IIBCAdmin.RecoveryConfig memory) {
        return IIBCAdmin.RecoveryConfig({
            delay: 30 days, threshold: 3, cancelThreshold: 3, silence: 30 days, holdPeriod: 14 days
        });
    }

    function _prefix() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = "main";
        p[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
    }

    function _candidate() internal returns (WritingCandidate) {
        return new WritingCandidate(address(router), d.accessManager, address(ics20), address(admin));
    }

    function _spent(uint8 kind, bytes memory params) internal returns (uint64 seq) {
        seq = admin.lastSeq() + 1;
        _recvGov(_env(seq, kind, params));
        _skip(7 days + 1);
        admin.execute(seq);
        assertEq(admin.decision(admin.epoch(), seq).state, S.SPENT, "refused");
    }

    function test_r11_static_kind6Verifier() public {
        WritingCandidate c = _candidate();
        uint64 last = admin.lastSeq();
        _spent(S.KIND_CLIENT, P.client(1, "gnoland-9", "ethereum-9", _prefix(), address(c), address(c).codehash));
        assertEq(c.writes(), 0, "the verifier's probes ran static");
        // a kind 6 migration of the live client to it, likewise
        _spent(S.KIND_CLIENT, P.client(2, clientId, CP, _prefix(), address(c), address(c).codehash));
        assertEq(c.writes(), 0);
        assertEq(admin.lastSeq(), last + 2, "nothing drained or recorded by the candidate");
    }

    function test_r11_static_recoveryProposalClient() public {
        WritingCandidate c = _candidate();
        IIBCAdmin.RecoveryProposal memory p = IIBCAdmin.RecoveryProposal({
            newClientId: "gnoland-r",
            counterpartyClientId: "ethereum-r",
            merklePrefix: _prefix(),
            lightClient: address(c),
            codeHash: address(c).codehash,
            suspectFrom: 0
        });
        // gno.land bound first (a recorded decision): a recovery waits for it
        _recvGov(_env(admin.lastSeq() + 1, S.KIND_SETTINGS, P.settings(clientId, 7 days)));
        lc.setStatus(true, false);
        vm.prank(G[0]);
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        admin.approveRecovery(p);
        assertEq(c.writes(), 0);
    }

    function test_r11_static_kind9Executor() public {
        WritingCandidate c = _candidate();
        // answered by a plain call, its bindings would pass the check
        (bool ok, bytes memory ret) = address(c).call(abi.encodeWithSignature("bindings()"));
        assertTrue(ok && ret.length == 96);
        assertEq(c.writes(), 1);
        _spent(S.KIND_HANDOVER, P.handover(address(c), address(c).codehash, ""));
        assertEq(c.writes(), 1, "probed static only");
        (address x,) = admin.exec();
        assertEq(x, d.ibcAdminExec);
    }

    function test_r11_static_kind7Implementation() public {
        WritingCandidate c = _candidate();
        _spent(S.KIND_UPGRADE, P.upgrade(address(ics20), address(c), address(c).codehash, ""));
        assertEq(c.writes(), 0, "probed static only");
        assertEq(
            vm.load(address(ics20), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc),
            bytes32(uint256(uint160(d.ics20Implementation)))
        );
    }
}
