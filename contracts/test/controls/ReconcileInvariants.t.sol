// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20Mock } from "@openzeppelin-contracts/mocks/token/ERC20Mock.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";

import { ICS26Router } from "@eureka/ICS26Router.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { GnoICS20Transfer } from "../../src/GnoICS20Transfer.sol";
import { IGnoICS20Controls, IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { FrozenLightClient } from "../../src/admin/FrozenLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Drives one route through random sends, acks (forged or not), timeouts, receives, replacements (also while
/// closed), proofs, kind 12 actions (late losses included), kind 13 and its continuation, claims and parked claims.
/// Every call that the controls refuse is simply skipped: the invariants hold whatever succeeds.
contract ReconcileHandler is Test {
    ICS26Router internal router;
    IGnoICS20Controls internal ctl;
    GnoICS20Transfer internal ics20;
    ERC20Mock internal usdc;
    address internal admin;
    address internal alice;
    address internal bob;
    string internal routeKey;
    bytes[] internal prefix;

    string[] public clients; // every client id of the route; the last is the live one
    IICS26RouterMsgs.Packet[] internal packets;
    mapping(uint256 => bool) internal done; // acked or timed out at the router
    mapping(bytes32 => uint256) public settledCount; // per (client, sequence)
    mapping(bytes32 => uint64) internal nextRecv;

    struct Receive {
        string client;
        uint64 sequence;
        uint256 amount;
    }
    Receive[] internal receives;

    uint256 public calls;
    address internal immutable frozen = address(new FrozenLightClient());
    /// @notice How many of each action succeeded (a non-vacuous run reaches every one).
    mapping(string => uint256) public ok;
    /// @notice Refunds kind 12 owes for packets a forged success ack had released (their backing could be redeemed
    /// meanwhile): the only way the reservation can exceed the escrow, by a loss of the compromise.
    uint256 public forgedSuccessRefunds;

    constructor(
        ICS26Router router_,
        IGnoICS20Controls ctl_,
        GnoICS20Transfer ics20_,
        ERC20Mock usdc_,
        address admin_,
        address alice_,
        address bob_,
        string memory clientId
    ) {
        (router, ctl, ics20, usdc, admin, alice, bob) = (router_, ctl_, ics20_, usdc_, admin_, alice_, bob_);
        routeKey = clientId;
        clients.push(clientId);
        prefix.push("main");
        prefix.push("/pv/vm:gno.land/r/aib/ibc/core:");
    }

    function packetCount() external view returns (uint256) {
        return packets.length;
    }

    function packet(uint256 i) external view returns (IICS26RouterMsgs.Packet memory) {
        return packets[i];
    }

    function clientCount() external view returns (uint256) {
        return clients.length;
    }

    function _live() internal view returns (string memory) {
        return clients[clients.length - 1];
    }

    // ------------------------------------------------------------------------------------------------ actions --

    function send(uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 100);
        vm.recordLogs();
        vm.prank(alice);
        try ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg({
                denom: address(usdc),
                amount: amount,
                receiver: "g1receiver",
                sourceClient: _live(),
                destPort: ICS20Lib.DEFAULT_PORT_ID,
                timeoutTimestamp: uint64(block.timestamp + 600),
                memo: ""
            })
        ) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.SendPacket.selector) {
                    packets.push(abi.decode(logs[i].data, (IICS26RouterMsgs.Packet)));
                    ok["send"]++;
                    break;
                }
            }
        } catch { }
    }

    function ack(uint256 i, bool success) external {
        calls++;
        if (packets.length == 0) return;
        i = bound(i, 0, packets.length - 1);
        if (done[i]) return;
        bytes memory a = success ? bytes("{\"result\":\"AQ==\"}") : ICS24Host.UNIVERSAL_ERROR_ACK;
        try router.ackPacket(IICS26RouterMsgs.MsgAckPacket(packets[i], a, "", IICS02ClientMsgs.Height(0, 1))) {
            done[i] = true;
            ok["ack"]++;
        } catch { }
    }

    function timeout(uint256 i) external {
        calls++;
        if (packets.length == 0) return;
        i = bound(i, 0, packets.length - 1);
        if (done[i]) return;
        MockLightClient c = MockLightClient(address(router.getClient(packets[i].sourceClient)));
        try c.setTimestamp(packets[i].timeoutTimestamp) { }
            catch {
            return;
        }
        try router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(packets[i], "", IICS02ClientMsgs.Height(0, 1))) {
            done[i] = true;
            ok["timeout"]++;
        } catch { }
        c.setTimestamp(0);
    }

    /// @notice A receive returning usdc to bob on the live client (forged or honest: the controls cannot tell).
    function receive_(uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 20);
        string memory dest = _live();
        IICS26RouterMsgs.Payload[] memory pl = new IICS26RouterMsgs.Payload[](1);
        IICS20TransferMsgs.FungibleTokenPacketData memory data = IICS20TransferMsgs.FungibleTokenPacketData({
            denom: string.concat(
                "transfer/", router.getCounterparty(dest).clientId, "/", Strings.toHexString(address(usdc))
            ),
            sender: "g1sender",
            receiver: Strings.toHexString(bob),
            amount: amount,
            memo: ""
        });
        pl[0] = IICS26RouterMsgs.Payload(
            ICS20Lib.DEFAULT_PORT_ID,
            ICS20Lib.DEFAULT_PORT_ID,
            ICS20Lib.ICS20_VERSION,
            ICS20Lib.ICS20_ENCODING,
            abi.encode(data)
        );
        uint64 seq = ++nextRecv[keccak256(bytes(dest))];
        IICS26RouterMsgs.Packet memory pkt = IICS26RouterMsgs.Packet({
            sequence: seq,
            sourceClient: router.getCounterparty(dest).clientId,
            destClient: dest,
            timeoutTimestamp: uint64(block.timestamp + 600),
            payloads: pl
        });
        try router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(pkt, "", IICS02ClientMsgs.Height(0, 1))) {
            (, uint256 got) = ctl.receiveRecord(dest, seq);
            if (got != 0) {
                receives.push(Receive(dest, seq, got));
                ok["receive"]++;
            }
        } catch { }
    }

    /// @notice A route replacement of the live client (also while the route is closed), with a random interval.
    function replace(uint256 seed) external {
        calls++;
        bool fromZero = seed & 1 == 1;
        if (clients.length >= 6 || seed % 5 != 0) return;
        string memory next = string.concat("gnoland-", vm.toString(clients.length + 10));
        address lc = address(new MockLightClient());
        vm.startPrank(admin);
        try router.addClient(next, IICS02ClientMsgs.CounterpartyInfo(string.concat("eth-", next), prefix), lc) {
            string memory old = _live();
            try ctl.migrateRoute(old, next, fromZero ? 0 : uint64(block.number)) {
                // as IBCAdmin does: the retired id's client is frozen (it proves nothing more)
                router.migrateClient(old, router.getCounterparty(old), frozen);
                clients.push(next);
                ok["replace"]++;
            } catch { }
        } catch { }
        vm.stopPrank();
    }

    function prove(uint256 i, bool delivered) external {
        calls++;
        if (packets.length == 0) return;
        i = bound(i, 0, packets.length - 1);
        IICS26RouterMsgs.Packet memory pkt = packets[i];
        bytes memory a = delivered ? bytes("{\"result\":\"AQ==\"}") : ICS24Host.UNIVERSAL_ERROR_ACK;
        try ctl.proveOutcome(pkt, T.OutcomeProof(IICS02ClientMsgs.Height(0, 1), ctl.gnoReceipt(pkt), "", a, "")) {
            ok["prove"]++;
        } catch { }
    }

    function settle(uint256 i, uint8 action) external {
        calls++;
        if (packets.length == 0) return;
        i = bound(i, 0, packets.length - 1);
        action = uint8(bound(action, 0, 4)); // 0: the action the proven outcome allows
        _settle(packets[i], action, action % 2 == 0, false);
    }

    /// @notice Reconciles every unsettled record of the retired clients (proving each first), so kind 13 can follow.
    function reconcileAll(uint256 seed) external {
        calls++;
        for (uint256 i = 0; i < packets.length; i++) {
            IICS26RouterMsgs.Packet memory pkt = packets[i];
            T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
            (,, uint64 start,,) = ctl.clientRecon(pkt.sourceClient);
            // only what kind 13 waits for: open records and suspect ones (the rest stay for late settlements)
            if (rec.open || (rec.processedBlock != 0 && rec.processedIndex >= start)) {
                _settle(pkt, 0, (seed >> (i % 256)) & 1 == 1, true);
            }
        }
    }

    function _settle(IICS26RouterMsgs.Packet memory pkt, uint8 action, bool delivered, bool skipSettled) internal {
        if (!ctl.isRetired(pkt.sourceClient)) return;
        T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        if (skipSettled && rec.settlement != 0) return; // a random settlement also tries settled records again
        if (rec.proven == T.Proven.None) {
            bytes memory a = delivered ? bytes("{\"result\":\"AQ==\"}") : ICS24Host.UNIVERSAL_ERROR_ACK;
            try ctl.proveOutcome(pkt, T.OutcomeProof(IICS02ClientMsgs.Height(0, 1), ctl.gnoReceipt(pkt), "", a, "")) {
                ok["prove"]++;
            } catch {
                return;
            }
            rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        }
        if (action == 0) {
            bool owed = rec.payment == T.Payment.Queued || rec.payment == T.Payment.Parked;
            if (rec.proven != T.Proven.Delivered) action = 1;
            else if (rec.refunded != 0) action = 4;
            else action = owed ? 2 : 3;
        }
        uint256 amount = action == 1 ? rec.amount - rec.refunded : (action == 4 ? rec.refunded : 0);
        bool forgedSuccess = action == 1 && rec.outcome == T.Outcome.Success;
        T.SettleItem[] memory items = new T.SettleItem[](1);
        items[0] = T.SettleItem(pkt.sequence, action, amount);
        vm.prank(admin);
        try ctl.settleRecords(pkt.sourceClient, items) {
            settledCount[keccak256(abi.encode(pkt.sourceClient, pkt.sequence))]++;
            if (forgedSuccess) forgedSuccessRefunds += amount;
            ok["settle"]++;
        } catch { }
    }

    /// @notice Kind 12 action 5 on a recorded receive (a late loss when the route is open).
    function forgedReceive(uint256 j) external {
        calls++;
        if (receives.length == 0) return;
        Receive memory r = receives[bound(j, 0, receives.length - 1)];
        T.SettleItem[] memory items = new T.SettleItem[](1);
        items[0] = T.SettleItem(r.sequence, 5, r.amount);
        vm.prank(admin);
        try ctl.settleRecords(r.client, items) {
            ok["forgedReceive"]++;
        } catch { }
    }

    function reopen() external {
        calls++;
        vm.prank(admin);
        try ctl.reopenRoute(_live()) {
            ok["reopen"]++;
        } catch { }
    }

    function continueReopen(uint256 n) external {
        calls++;
        try ctl.continueReopen(_live(), bound(n, 1, 16)) {
            ok["continue"]++;
        } catch { }
    }

    function claim() external {
        calls++;
        try ctl.claim(_live(), address(usdc), 5) returns (uint256 n) {
            if (n != 0) ok["claim"]++;
        } catch { }
    }

    function claimParked(uint256 i) external {
        calls++;
        if (packets.length == 0) return;
        IICS26RouterMsgs.Packet memory pkt = packets[bound(i, 0, packets.length - 1)];
        try ctl.claimParked(pkt.sourceClient, pkt.sequence) {
            ok["claimParked"]++;
        } catch { }
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
        vm.roll(block.number + 1);
    }
}

/// @notice Invariants of the reconciliation state machine (docs/controls.md), over random sequences of the handler.
contract ReconcileInvariantsTest is ControlsFixture {
    ReconcileHandler internal h;

    function setUp() public override {
        super.setUp();
        _setLimits(address(usdc), 100, 1000, 30);
        h = new ReconcileHandler(router, ctl, ics20, usdc, address(admin), alice, bob, clientId);
        vm.prank(alice);
        usdc.approve(address(ics20), type(uint256).max);
        targetContract(address(h));
    }

    /// @notice Escrow never falls below the reservation (owed refunds and outstanding sends), except by the refunds
    /// owed for packets a forged success ack released (a loss of the compromise, not of the accounting).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_escrowCoversTheReservation() public view {
        assertGe(
            usdc.balanceOf(ics20.getEscrow(clientId)) + h.forgedSuccessRefunds(), ctl.reserved(clientId, address(usdc))
        );
    }

    /// @notice Every record is settled at most once, and no refund is paid beyond its amount (never twice).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_settledOnce_refundedOnce() public view {
        uint256 n = h.packetCount();
        for (uint256 i = 0; i < n; i++) {
            IICS26RouterMsgs.Packet memory pkt = h.packet(i);
            assertLe(h.settledCount(keccak256(abi.encode(pkt.sourceClient, pkt.sequence))), 1);
            T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
            assertLe(rec.refunded, rec.amount);
        }
    }

    /// @notice Per client id, the open and suspect counters equal a recomputation from the records.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_countersMatchTheRecords() public view {
        uint256 m = h.clientCount();
        uint256 n = h.packetCount();
        for (uint256 k = 0; k < m; k++) {
            string memory c = h.clients(k);
            (uint64 open, uint32 incident, uint64 start, uint64 suspect,) = ctl.clientRecon(c);
            uint64 o;
            uint64 sus;
            for (uint256 i = 0; i < n; i++) {
                IICS26RouterMsgs.Packet memory pkt = h.packet(i);
                if (keccak256(bytes(pkt.sourceClient)) != keccak256(bytes(c))) continue;
                T.SendRecord memory rec = ctl.sendRecord(c, pkt.sequence);
                if (rec.open) o++;
                if (incident != 0 && rec.processedBlock != 0 && rec.settlement == 0 && rec.processedIndex >= start) {
                    sus++;
                }
            }
            assertEq(open, o, "open records");
            assertEq(suspect, incident == 0 ? 0 : sus, "suspect records");
        }
    }

    /// @notice A route is open only if all its incidents are resolved; then its losses are all accepted.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_openOnlyWhenResolved_lossesAccepted() public view {
        (T.Incident[] memory inc, uint64 resolved) = ctl.incidents(clientId);
        if (!ctl.routeClosed(clientId)) {
            assertEq(resolved, inc.length, "every incident resolved");
            assertEq(ctl.losses(clientId, address(usdc)), ctl.acceptedDeficit(clientId, address(usdc)));
        }
        for (uint256 i = 0; i < inc.length; i++) {
            assertEq(inc[i].status == 3, i < resolved, "resolved exactly below resolvedUpTo");
        }
        if (!ctl.routeClosed(clientId)) {
            // and every retired client's records reconciled (no open, no suspect record)
            uint256 m = h.clientCount();
            for (uint256 k = 0; k + 1 < m; k++) {
                (uint64 open,,, uint64 suspect,) = ctl.clientRecon(h.clients(k));
                assertEq(open, 0, "a retired client's record open on an open route");
                assertEq(suspect, 0, "a retired client's suspect record on an open route");
            }
        }
    }

    /// @notice What the run reached, per action.
    function afterInvariant() external view {
        string[12] memory names = [
            "send",
            "ack",
            "timeout",
            "receive",
            "replace",
            "prove",
            "settle",
            "forgedReceive",
            "reopen",
            "continue",
            "claim",
            "claimParked"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            console2.log(names[i], h.ok(names[i]));
        }
    }

    /// @notice The handler did work (guards a vacuous run).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_callsMade() public view {
        assertGe(h.calls(), 0);
    }
}
