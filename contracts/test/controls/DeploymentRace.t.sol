// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ICS26Router } from "@eureka/ICS26Router.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";

import { DeployGnoIBC } from "../../script/DeployGnoIBC.s.sol";
import { IGnoICS20Controls, IGnoICS20ControlsTypes } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdmin } from "../../src/admin/IBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { Fixtures } from "../utils/Fixtures.sol";
import { GnoLightClient } from "../../src/GnoLightClient.sol";
import { IGnoLightClientMsgs as Msgs } from "../../src/msgs/IGnoLightClientMsgs.sol";

/// @notice Round 15 #1: the launch client binding against an attacker registering a client between the deployer's
/// transactions (eureka's generated-id `addClient` is permissionless).
abstract contract RaceBase is Test, DeployGnoIBC {
    address internal deployer = makeAddr("deployer");
    address internal attacker = makeAddr("attacker");
    MockLightClient internal theirs; // the attacker's verifier: it proves anything
    Deployed internal d;
    bytes internal finishError;

    function _params() internal returns (Params memory p) {
        vm.warp(1_700_000_000);
        vm.roll(1000);
        p.deployer = deployer;
        p.lightClient = address(new MockLightClient());
        p.counterparty = "ethereum-1";
        for (uint256 i = 0; i < 4; i++) {
            p.guardians[i] = makeAddr(string.concat("guardian", vm.toString(i)));
        }
        p.watch = [makeAddr("watch0"), makeAddr("watch1")];
        p.clientState.chainId = "gno-test";
        p.expectedLock = 1_000_000e6;
        p.gnotLimits = IGnoICS20ControlsTypes.Limits(25_000e6, 100_000e6, 100_000e6, 0, 0);
        p.quarantineSeconds = 7 days;
        theirs = new MockLightClient();
    }

    function _deployAll() internal {
        Params memory p = _params();
        vm.startPrank(deployer);
        d = _deploy(p);
        vm.stopPrank();
    }

    /// @notice The attacker's registration, as a transaction of its own between two of the deployer's.
    function _attackerRegisters(address router) internal returns (string memory id) {
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = GNO_STORE;
        prefix[1] = GNO_KEY_PREFIX;
        vm.stopPrank();
        vm.prank(attacker);
        id = ICS26Router(router).addClient(IICS02ClientMsgs.CounterpartyInfo("ethereum-1", prefix), address(theirs));
        vm.startPrank(deployer);
    }

    /// @notice A governance decision relayed over `clientId` (the attacker's verifier proves whatever it is asked).
    function _govOver(string memory clientId) internal returns (bytes memory ack) {
        IBCAdmin admin = IBCAdmin(d.ibcAdmin);
        bytes memory env = abi.encodePacked(uint8(1), uint32(1), uint64(1), S.KIND_UNPAUSE, P.unpause(1, clientId));
        IICS26RouterMsgs.Payload[] memory pl = new IICS26RouterMsgs.Payload[](1);
        pl[0] = IICS26RouterMsgs.Payload("gov", "ibcgov", "ibcgov-1", "application/x-ibcgov", env);
        IICS26RouterMsgs.Packet memory pkt = IICS26RouterMsgs.Packet({
            sequence: 1,
            sourceClient: ICS26Router(d.ics26Router).getCounterparty(clientId).clientId,
            destClient: clientId,
            timeoutTimestamp: uint64(block.timestamp + 1 hours),
            payloads: pl
        });
        vm.recordLogs();
        ICS26Router(d.ics26Router).recvPacket(IICS26RouterMsgs.MsgRecvPacket(pkt, "", IICS02ClientMsgs.Height(0, 1)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        admin; // the ack is the router's
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IICS26Router.WriteAcknowledgement.selector) {
                (, bytes[] memory acks) = abi.decode(logs[i].data, (IICS26RouterMsgs.Packet, bytes[]));
                return acks[0];
            }
        }
        revert("no acknowledgement written");
    }
}

/// @notice The deployment as it is: the router and its launch client in one transaction (RouterLauncher). An
/// attacker registering right after gets the next id, which nothing names.
contract DeploymentRaceTest is RaceBase {
    string internal attackerId;

    function _afterRouter(Deployed memory dd) internal override {
        attackerId = _attackerRegisters(dd.ics26Router);
    }

    function test_r15_1_attackerBetweenTransactions_capturesNothing() public {
        _deployAll();
        IBCAdmin admin = IBCAdmin(d.ibcAdmin);
        assertEq(d.clientId, "client-0");
        assertEq(attackerId, "client-1", "the attacker's client comes after the launch client");
        assertEq(admin.govClient(), "client-0");
        assertEq(address(ICS26Router(d.ics26Router).getClient("client-0")), d.gnoLightClient);
        assertTrue(admin.setupDone());
        // governance over the attacker's client is refused, nothing recorded
        bytes memory ack = _govOver(attackerId);
        assertEq(keccak256(ack), ICS24Host.KECCAK256_UNIVERSAL_ERROR_ACK);
        assertEq(admin.lastSeq(), 0);
    }
}

/// @notice The flow before round 15, emulated: the router deployed in one transaction, the client registered in
/// another with the generated-id overload, and every later step naming the id the simulation predicted. The
/// attacker takes that id in between; `finishSetup` finds the epoch's client is not the deployment's verifier, and
/// governance never starts.
contract DeploymentRaceOldFlowTest is RaceBase {
    function _launchRouter(
        address am,
        IICS02ClientMsgs.CounterpartyInfo memory counterparty,
        Deployed memory dd
    )
        internal
        override
        returns (address router, string memory clientId)
    {
        router = address(new ERC1967Proxy(address(new ICS26Router()), abi.encodeCall(ICS26Router.initialize, (am))));
        _attackerRegisters(router); // takes client-0
        ICS26Router(router).addClient(counterparty, dd.gnoLightClient); // the deployer's: client-1
        clientId = "client-0"; // what the simulation predicted, and what every later transaction names
    }

    function _finish(Params memory p, Deployed memory dd) internal override {
        try IBCAdmin(dd.ibcAdmin).finishSetup(_launch(p, dd)) { }
        catch (bytes memory r) {
            finishError = r;
        }
    }

    function test_r15_1_oldFlowCapture_failsSetup_governanceOff() public {
        _deployAll();
        IBCAdmin admin = IBCAdmin(d.ibcAdmin);
        assertEq(address(ICS26Router(d.ics26Router).getClient("client-0")), address(theirs), "captured id");
        assertEq(
            keccak256(finishError), keccak256(abi.encodeWithSelector(IIBCAdmin.SetupIncomplete.selector, uint8(11)))
        );
        assertFalse(admin.setupDone());
        // the attacker's verifier proves a governance decision: refused, nothing recorded or executed
        bytes memory ack = _govOver("client-0");
        assertEq(keccak256(ack), ICS24Host.KECCAK256_UNIVERSAL_ERROR_ACK);
        assertEq(admin.lastSeq(), 0);
        vm.expectRevert(IIBCAdmin.SetupPending.selector);
        admin.execute(1);
    }
}

/// @notice Round 16 #1: the launch record names the verifier's original checkpoint, not its current state. With the
/// real GnoLightClient, anyone relays an honest update between the deployment and `finishSetup`: setup still passes.
contract DeploymentRealClientTest is Fixtures, DeployGnoIBC {
    address internal deployer = makeAddr("deployer");
    address internal relayer = makeAddr("anyone");
    Deployed internal d;

    function _finish(Params memory p, Deployed memory dd) internal override {
        vm.stopPrank();
        vm.prank(relayer);
        GnoLightClient(dd.gnoLightClient).updateClient(_msg("h11")); // a verified forward update, front-running
        vm.startPrank(deployer);
        super._finish(p, dd);
    }

    function test_r16_1_honestUpdateBeforeFinishSetup_setupPasses() public {
        _loadFixtures();
        vm.warp(t0Seconds + 120);
        Params memory p;
        p.deployer = deployer;
        p.clientState = _initialClientState();
        p.consensusState = _initialConsensusState();
        p.counterparty = "ethereum-1";
        for (uint256 i = 0; i < 4; i++) {
            p.guardians[i] = makeAddr(string.concat("guardian", vm.toString(i)));
        }
        p.watch = [makeAddr("watch0"), makeAddr("watch1")];
        p.expectedLock = 1_000_000e6;
        p.gnotLimits = IGnoICS20ControlsTypes.Limits(25_000e6, 100_000e6, 100_000e6, 0, 0);
        p.quarantineSeconds = 7 days;
        vm.startPrank(deployer);
        d = _deploy(p);
        vm.stopPrank();
        Msgs.ClientState memory cs = abi.decode(GnoLightClient(d.gnoLightClient).getClientState(), (Msgs.ClientState));
        assertEq(cs.latestHeight, 11, "advanced past the launch height");
        assertTrue(IBCAdmin(d.ibcAdmin).setupDone(), "the original checkpoint still checks");
    }
}

/// @notice Round 16 #1, the sweep of `finishSetup` for state a third party can advance: two guardians flagging
/// IBCAdmin before setup would leave a hold in its history (check 40). Flags wait for setup.
contract DeploymentFlagsBeforeSetupTest is RaceBase {
    function _finish(Params memory p, Deployed memory dd) internal override {
        vm.stopPrank();
        for (uint256 g = 0; g < 2; g++) {
            vm.prank(p.guardians[g]);
            vm.expectRevert(IIBCAdmin.SetupPending.selector);
            IBCAdmin(dd.ibcAdmin).setFlag();
        }
        vm.startPrank(deployer);
        super._finish(p, dd);
    }

    function test_r16_1_flagsBeforeSetup_cannotBlockIt() public {
        _deployAll();
        assertTrue(IBCAdmin(d.ibcAdmin).setupDone());
    }
}

/// @notice Round 19 #2: the launch quarantine is armed before receives exist, and covers transitions relayed between
/// the deployment's transactions. With the real GnoLightClient, anyone relays h11 and then h12 (which announces
/// another validator set: a transition) right after the router's launch, before the quarantine is set. The launch
/// duration still applies to that transition, so receives wait for it.
contract DeploymentQuarantineTest is Fixtures, DeployGnoIBC {
    address internal deployer = makeAddr("deployer");
    Deployed internal d;
    uint64 internal transitionTime;

    function _afterRouter(Deployed memory dd) internal override {
        vm.stopPrank();
        vm.startPrank(makeAddr("anyone"));
        GnoLightClient(dd.gnoLightClient).updateClient(_msg("h11"));
        GnoLightClient(dd.gnoLightClient).updateClient(_msg("h12")); // a transition
        vm.stopPrank();
        transitionTime = GnoLightClient(dd.gnoLightClient).lastTransitionTime();
        vm.startPrank(deployer);
    }

    function test_r19_2_transitionBeforeArming_stillQuarantined() public {
        _loadFixtures();
        vm.warp(t0Seconds + 120);
        Params memory p;
        p.deployer = deployer;
        p.clientState = _initialClientState();
        p.consensusState = _initialConsensusState();
        p.counterparty = "ethereum-1";
        for (uint256 i = 0; i < 4; i++) {
            p.guardians[i] = makeAddr(string.concat("guardian", vm.toString(i)));
        }
        p.watch = [makeAddr("watch0"), makeAddr("watch1")];
        p.expectedLock = 1_000_000e6;
        p.gnotLimits = IGnoICS20ControlsTypes.Limits(25_000e6, 100_000e6, 100_000e6, 0, 0);
        p.quarantineSeconds = 7 days;
        vm.startPrank(deployer);
        d = _deploy(p);
        vm.stopPrank();
        assertGt(transitionTime, 0, "h12 was a transition");
        IGnoICS20Controls ctl = IGnoICS20Controls(d.ics20Transfer);
        assertEq(ctl.quarantineEnd(d.clientId), uint256(transitionTime) + 7 days, "the launch duration applies");
        assertTrue(IBCAdmin(d.ibcAdmin).setupDone());
    }
}

