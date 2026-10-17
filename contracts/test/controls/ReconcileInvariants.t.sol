// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { ERC20Mock } from "@openzeppelin-contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";

import { ICS26Router } from "@eureka/ICS26Router.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS20Transfer } from "@eureka/interfaces/IICS20Transfer.sol";
import { IIBCSenderCallbacks } from "@eureka/interfaces/IIBCSenderCallbacks.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { GnoICS20Transfer } from "../../src/GnoICS20Transfer.sol";
import { IGnoICS20Controls, IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdmin } from "../../src/admin/IBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { HookToken, SenderAdapter } from "../utils/ControlsMocks.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Called from a token hook while the transfer app runs: a governance delivery and a drain record nothing.
contract BusyProbe {
    ICS26Router internal immutable router;
    IBCAdmin internal immutable admin;
    bool public delivered;
    bool public drained;

    constructor(ICS26Router r, IBCAdmin a) {
        (router, admin) = (r, a);
    }

    function probe(IICS26RouterMsgs.Packet calldata gov) external {
        uint64 before = admin.lastSeq();
        try router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(gov, "", IICS02ClientMsgs.Height(0, 1))) {
            delivered = admin.lastSeq() == before; // an error ack (Busy): nothing recorded
        } catch {
            delivered = admin.lastSeq() == before;
        }
        drained = admin.drain() == 0 && admin.lastSeq() == before;
    }
}

/// @notice The ghost model and the actions of the invariant campaign. Every packet's truth (delivered or not) is
/// chosen when it is sent; relays are honest or forged against it; proofs are honest (through the active client):
/// every refund, reservation, settlement and loss is checked against the truth, independently of the controls'
/// own bookkeeping. Governance (kinds 6, 10, 12, 13) runs through IBCAdmin.execute.
contract ReconcileHandler is Test {
    ICS26Router internal router;
    IGnoICS20Controls internal ctl;
    GnoICS20Transfer internal ics20;
    IBCAdmin internal admin;
    address internal alice;
    address internal bob;
    address[4] internal G;
    BusyProbe internal busyProbe;
    SenderAdapter internal adapter;

    address[] public tokens; // usdc first; seventeen more (deficits beyond one batch); the hook token last
    HookToken internal hookToken;
    mapping(address => bool) internal limited;

    struct Ghost {
        bool delivered; // the destination's truth
        bool forgedSuccess; // a success ack relayed for an undelivered packet
        bool forgedRefund; // an error ack or timeout relayed for a delivered packet
        bool relayed; // acked or timed out at the router
        address sender;
    }

    IICS26RouterMsgs.Packet[] internal packets;
    mapping(uint256 => Ghost) public ghost;
    mapping(bytes32 => uint256) public settledCount;

    struct Receive {
        string client;
        uint64 sequence;
        uint256 amount;
        address token;
        bool forged;
    }

    Receive[] internal receives;
    mapping(bytes32 => uint64) internal nextRecv;
    mapping(address => uint256) public redeemable; // vouchers on gno.land of delivered sends, per token

    string[] public clients; // every client id of the route, in order; the last is the live one
    uint256 public calls;
    mapping(string => uint256) public ok;

    constructor(
        ICS26Router router_,
        IGnoICS20Controls ctl_,
        GnoICS20Transfer ics20_,
        IBCAdmin admin_,
        address alice_,
        address bob_,
        address[4] memory guardians,
        string memory clientId,
        address usdc
    ) {
        (router, ctl, ics20, admin, alice, bob, G) = (router_, ctl_, ics20_, admin_, alice_, bob_, guardians);
        clients.push(clientId);
        tokens.push(usdc);
        for (uint256 i = 0; i < 17; i++) {
            ERC20Mock t = new ERC20Mock();
            t.mint(alice, 1e30);
            tokens.push(address(t));
        }
        hookToken = new HookToken();
        hookToken.mint(alice, 1e30);
        tokens.push(address(hookToken));
        for (uint256 i = 0; i < tokens.length; i++) {
            vm.prank(alice);
            IERC20(tokens[i]).approve(address(ics20), type(uint256).max);
        }
        busyProbe = new BusyProbe(router, admin);
        adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(usdc), address(0xADA));
    }

    // ------------------------------------------------------------------------------------------------ views --

    function packetCount() external view returns (uint256) {
        return packets.length;
    }

    function packet(uint256 i) external view returns (IICS26RouterMsgs.Packet memory) {
        return packets[i];
    }

    function receiveCount() external view returns (uint256) {
        return receives.length;
    }

    function receiveAt(uint256 i) external view returns (Receive memory) {
        return receives[i];
    }

    function clientCount() external view returns (uint256) {
        return clients.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function _live() internal view returns (string memory) {
        return clients[clients.length - 1];
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _skip(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 1 + dt / 12);
    }

    function _prefix() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = "main";
        p[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
    }

    function _liveClient() internal view returns (MockLightClient) {
        return MockLightClient(address(router.getClient(_live())));
    }

    // ------------------------------------------------------------------------------------------- governance --

    function _govPacket(bytes memory envelope) internal returns (IICS26RouterMsgs.Packet memory pkt) {
        string memory gov = admin.govClient();
        IICS26RouterMsgs.Payload[] memory pl = new IICS26RouterMsgs.Payload[](1);
        pl[0] = IICS26RouterMsgs.Payload("gov", "ibcgov", "ibcgov-1", "application/x-ibcgov", envelope);
        pkt = IICS26RouterMsgs.Packet({
            sequence: ++nextRecv[keccak256(bytes(gov))],
            sourceClient: router.getCounterparty(gov).clientId,
            destClient: gov,
            timeoutTimestamp: uint64(_now() + 1 hours),
            payloads: pl
        });
    }

    /// @notice Records a decision through the router and IBCAdmin; zero unless it was recorded pending.
    function _decide(uint8 kind, bytes memory params) internal returns (uint64 seq) {
        seq = admin.lastSeq() + 1;
        bytes memory env = abi.encodePacked(uint8(1), admin.epoch(), seq, kind, params);
        try router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(_govPacket(env), "", IICS02ClientMsgs.Height(0, 1))) { }
        catch {
            return 0;
        }
        if (admin.decision(admin.epoch(), seq).state != S.PENDING) return 0;
    }

    /// @notice Matures and executes recorded decisions, in order; whether all executed.
    function _executeAll(uint64[] memory seqs) internal returns (bool all) {
        _skip(7 days + 1);
        all = true;
        uint32 ep = admin.epoch();
        for (uint256 i = 0; i < seqs.length; i++) {
            if (seqs[i] == 0) {
                all = false;
                continue;
            }
            try admin.execute(seqs[i]) { } catch { }
            if (admin.decision(ep, seqs[i]).state != S.EXECUTED) all = false;
        }
    }

    function _one(uint64 s) internal pure returns (uint64[] memory a) {
        a = new uint64[](1);
        a[0] = s;
    }

    function _limits(address token) internal {
        if (limited[token]) return;
        vm.prank(address(admin));
        // usdc's refund meter is small, so refunds queue and claims pay them
        ctl.setLimits(_live(), token, T.Limits(1e24, 1e25, token == tokens[0] ? 50 : 1e24, 0, 0));
        limited[token] = true;
    }

    // -------------------------------------------------------------------------------------------- transport --

    function _record(bool delivered, address from, address token, uint256 amount) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.SendPacket.selector) {
                packets.push(abi.decode(logs[i].data, (IICS26RouterMsgs.Packet)));
                ghost[packets.length - 1] = Ghost(delivered, false, false, false, from);
                if (delivered) redeemable[token] += amount;
                return true;
            }
        }
        return false;
    }

    function _send(address from, address token, uint256 amount, bool delivered) internal returns (bool) {
        _limits(token);
        vm.recordLogs();
        vm.prank(from);
        try ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg({
                denom: token,
                amount: amount,
                receiver: "g1receiver",
                sourceClient: _live(),
                destPort: ICS20Lib.DEFAULT_PORT_ID,
                timeoutTimestamp: uint64(_now() + 600),
                memo: ""
            })
        ) {
            return _record(delivered, from, token, amount);
        } catch { }
        return false;
    }

    function send(uint256 tokenSeed, uint256 amount, bool delivered) external {
        calls++;
        address token = tokens[tokenSeed % 2 == 0 ? 0 : bound(tokenSeed, 0, tokens.length - 1)];
        if (_send(alice, token, bound(amount, 1, 100), delivered)) ok["send"]++;
    }

    /// @notice A contract sender (notified through IIBCSenderCallbacks; it takes callbacks only from ICS20).
    function sendFromAdapter(uint256 amount, bool delivered) external {
        calls++;
        amount = bound(amount, 1, 100);
        ERC20Mock(tokens[0]).mint(address(adapter), amount);
        _limits(tokens[0]);
        vm.recordLogs();
        try adapter.send(amount, _live()) {
            if (_record(delivered, address(adapter), tokens[0], amount)) ok["sendFromAdapter"]++;
        } catch { }
    }

    /// @notice Relays a packet's outcome, honestly or forged against its truth.
    function relay(uint256 i, bool forged, bool useTimeout) external {
        calls++;
        if (packets.length == 0) return;
        i = bound(i, 0, packets.length - 1);
        if (ghost[i].relayed) return;
        IICS26RouterMsgs.Packet memory pkt = packets[i];
        bool success = ghost[i].delivered != forged;
        bool done;
        if (success) {
            try router.ackPacket(
                IICS26RouterMsgs.MsgAckPacket(pkt, bytes("{\"result\":\"AQ==\"}"), "", IICS02ClientMsgs.Height(0, 1))
            ) {
                done = true;
            } catch { }
        } else if (useTimeout) {
            MockLightClient c = MockLightClient(address(router.getClient(pkt.sourceClient)));
            try c.setTimestamp(pkt.timeoutTimestamp) {
                try router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(pkt, "", IICS02ClientMsgs.Height(0, 1))) {
                    done = true;
                } catch { }
                c.setTimestamp(0);
            } catch { }
        } else {
            try router.ackPacket(
                IICS26RouterMsgs.MsgAckPacket(pkt, ICS24Host.UNIVERSAL_ERROR_ACK, "", IICS02ClientMsgs.Height(0, 1))
            ) {
                done = true;
            } catch { }
        }
        if (!done) return;
        ghost[i].relayed = true;
        if (forged && success) ghost[i].forgedSuccess = true;
        if (forged && !success) ghost[i].forgedRefund = true;
        ok[forged ? "relayForged" : "relayHonest"]++;
    }

    /// @notice A receive returning a token to bob: honest (vouchers of a delivered send) or forged.
    function receive_(uint256 tokenSeed, uint256 amount, bool forged) external {
        calls++;
        address token = tokens[tokenSeed % 2 == 0 ? 0 : bound(tokenSeed, 0, tokens.length - 1)];
        amount = bound(amount, 1, 50);
        if (!forged && redeemable[token] < amount) return;
        string memory dest = _live();
        IICS26RouterMsgs.Payload[] memory pl = new IICS26RouterMsgs.Payload[](1);
        pl[0] = IICS26RouterMsgs.Payload(
            ICS20Lib.DEFAULT_PORT_ID,
            ICS20Lib.DEFAULT_PORT_ID,
            ICS20Lib.ICS20_VERSION,
            ICS20Lib.ICS20_ENCODING,
            abi.encode(
                IICS20TransferMsgs.FungibleTokenPacketData({
                    denom: string.concat(
                        "transfer/", router.getCounterparty(dest).clientId, "/", Strings.toHexString(token)
                    ),
                    sender: "g1sender",
                    receiver: Strings.toHexString(bob),
                    amount: amount,
                    memo: ""
                })
            )
        );
        uint64 seq = ++nextRecv[keccak256(bytes(dest))];
        IICS26RouterMsgs.Packet memory pkt = IICS26RouterMsgs.Packet({
            sequence: seq,
            sourceClient: router.getCounterparty(dest).clientId,
            destClient: dest,
            timeoutTimestamp: uint64(_now() + 600),
            payloads: pl
        });
        try router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(pkt, "", IICS02ClientMsgs.Height(0, 1))) {
            (, uint256 got) = ctl.receiveRecord(dest, seq);
            if (got != 0) {
                receives.push(Receive(dest, seq, got, token, forged));
                if (!forged) redeemable[token] -= amount;
                ok[forged ? "receiveForged" : "receiveHonest"]++;
            }
        } catch { }
    }

    function claim(uint256 tokenSeed) external {
        calls++;
        try ctl.claim(_live(), tokens[bound(tokenSeed, 0, tokens.length - 1)], 5) returns (uint256 n) {
            if (n != 0) ok["claim"]++;
        } catch { }
    }

    function claimParked(uint256 i) external {
        calls++;
        if (packets.length == 0) return;
        IICS26RouterMsgs.Packet memory pkt = packets[bound(i, 0, packets.length - 1)];
        try ctl.claimParked(pkt.sourceClient, pkt.sequence, 300_000) {
            ok["claimParked"]++;
        } catch { }
    }

    /// @notice A guardian's refunds flag, set or cleared.
    function refundsFlag(uint256 seat, bool set) external {
        calls++;
        vm.prank(G[bound(seat, 0, 3)]);
        if (set) {
            try ctl.setRefundsFlag(_live()) {
                ok["refundsFlag"]++;
            } catch { }
        } else {
            try ctl.clearRefundsFlag(_live()) {
                ok["refundsFlag"]++;
            } catch { }
        }
    }

    /// @notice A notification of an adapter's packet: a transport retry or the reconciliation's, with a budget.
    function notify(uint256 i) external {
        calls++;
        uint256 n = packets.length;
        for (uint256 k = 0; k < n; k++) {
            uint256 j = (i + k) % n;
            if (ghost[j].sender != address(adapter)) continue;
            IICS26RouterMsgs.Packet memory pkt = packets[j];
            bool done;
            try ctl.retryNotification(pkt.sourceClient, pkt.sequence, _timeoutNotice(pkt), 200_000) returns (bool d) {
                done = d;
            } catch { }
            if (!done) {
                try ctl.retryNotification(pkt.sourceClient, pkt.sequence, _errorNotice(pkt), 200_000) returns (bool d) {
                    done = d;
                } catch { }
            }
            if (!done) {
                try ctl.notifySettled(pkt, bytes("{\"result\":\"AQ==\"}"), 200_000) returns (bool d) {
                    done = d;
                } catch { }
            }
            if (done) {
                ok["notify"]++;
                return;
            }
        }
    }

    function _errorNotice(IICS26RouterMsgs.Packet memory pkt) internal view returns (bytes memory) {
        return abi.encodeCall(
            IIBCSenderCallbacks.onAckPacket,
            (
                false,
                IIBCAppCallbacks.OnAcknowledgementPacketCallback(
                    pkt.sourceClient,
                    pkt.destClient,
                    pkt.sequence,
                    pkt.payloads[0],
                    ICS24Host.UNIVERSAL_ERROR_ACK,
                    address(this)
                )
            )
        );
    }

    function _timeoutNotice(IICS26RouterMsgs.Packet memory pkt) internal view returns (bytes memory) {
        return abi.encodeCall(
            IIBCSenderCallbacks.onTimeoutPacket,
            (IIBCAppCallbacks.OnTimeoutPacketCallback(
                    pkt.sourceClient, pkt.destClient, pkt.sequence, pkt.payloads[0], address(this)
                ))
        );
    }

    /// @notice Governance delivery and drain from a token hook while the transfer app runs: nothing is recorded.
    function busyGovernance(uint256 amount) external {
        calls++;
        bytes memory env = abi.encodePacked(
            uint8(1), admin.epoch(), admin.lastSeq() + 1, S.KIND_SETTINGS, P.settings(_live(), 30 days)
        );
        IICS26RouterMsgs.Packet memory gov = _govPacket(env);
        if (!_send(alice, address(hookToken), bound(amount, 1, 10), false)) return;
        hookToken.setHook(alice, address(busyProbe), abi.encodeCall(BusyProbe.probe, (gov)));
        uint256 i = packets.length - 1;
        try router.ackPacket(
            IICS26RouterMsgs.MsgAckPacket(packets[i], ICS24Host.UNIVERSAL_ERROR_ACK, "", IICS02ClientMsgs.Height(0, 1))
        ) {
            ghost[i].relayed = true;
            if (hookToken.hookOk() && busyProbe.delivered() && busyProbe.drained()) ok["busyGovernance"]++;
        } catch { }
        hookToken.setHook(address(0), address(0), "");
    }

    // -------------------------------------------------------------------------------------------- verifiers --

    /// @notice The live verifier freezes or expires (proofs through it are void), or kind 6 migrates it.
    function verifierEvent(uint256 what) external {
        calls++;
        what = bound(what, 0, 2);
        if (what == 0) {
            _liveClient().setStatus(true, false);
            ok["verifierFreeze"]++;
        } else if (what == 1) {
            _liveClient().setStatus(false, true);
            ok["verifierExpire"]++;
        } else {
            MockLightClient fresh = new MockLightClient();
            string memory live = _live();
            uint64 s = _decide(
                S.KIND_CLIENT,
                P.client(
                    2, live, router.getCounterparty(live).clientId, _prefix(), address(fresh), address(fresh).codehash
                )
            );
            if (_executeAll(_one(s))) ok["verifierMigrate"]++;
        }
    }

    // ------------------------------------------------------------------------------------------ replacement --

    /// @notice Kind 6 adds a client and kind 10 replaces the live one with it, through IBCAdmin.execute (also while
    /// the route is closed or reopening).
    function _replace(bool fromZero) internal returns (bool) {
        string memory next = string.concat("gnoland-", vm.toString(100 + clients.length));
        MockLightClient fresh = new MockLightClient();
        uint64[] memory seqs = new uint64[](2);
        seqs[0] = _decide(
            S.KIND_CLIENT,
            P.client(
                1,
                next,
                string.concat("ethereum-", vm.toString(clients.length)),
                _prefix(),
                address(fresh),
                address(fresh).codehash
            )
        );
        seqs[1] = _decide(S.KIND_ROUTE, P.route(_live(), next, fromZero ? 0 : uint64(vm.getBlockNumber())));
        if (!_executeAll(seqs)) return false;
        clients.push(next);
        return true;
    }

    function replace(bool fromZero) external {
        calls++;
        if (clients.length >= 6) return;
        if (_replace(fromZero)) ok["replace"]++;
    }

    /// @notice The emergency recovery: the governance client goes bad, three guardians approve an attested client,
    /// and after the delay anyone executes it.
    function recover() external {
        calls++;
        if (clients.length >= 6) return;
        string memory next = string.concat("gnoland-", vm.toString(100 + clients.length));
        MockLightClient fresh = new MockLightClient();
        _liveClient().setStatus(true, false);
        IIBCAdmin.RecoveryProposal memory p = IIBCAdmin.RecoveryProposal({
            newClientId: next,
            counterpartyClientId: string.concat("ethereum-", vm.toString(clients.length)),
            merklePrefix: _prefix(),
            lightClient: address(fresh),
            codeHash: address(fresh).codehash,
            suspectFrom: 0
        });
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(G[i]);
            try admin.approveRecovery(p) { }
            catch {
                return;
            }
        }
        _skip(30 days + 1);
        try admin.executeRecovery() {
            clients.push(next);
            ok["recover"]++;
        } catch { }
    }

    // --------------------------------------------------------------------------------------- reconciliation --

    /// @notice Proves a record's outcome honestly, through the active client: a delivered one by its receipt and a
    /// success ack; an undelivered one by an error ack, a collision, or a non-receipt past its timeout.
    function _prove(uint256 i, uint256 how) internal returns (bool done) {
        IICS26RouterMsgs.Packet memory pkt = packets[i];
        T.OutcomeProof memory proof;
        proof.proofHeight = IICS02ClientMsgs.Height(0, 1);
        how = how % 3;
        if (ghost[i].delivered) {
            proof.receipt = ctl.gnoReceipt(pkt);
            proof.ack = bytes("{\"result\":\"AQ==\"}");
        } else if (how == 0) {
            proof.receipt = ctl.gnoReceipt(pkt);
            proof.ack = ICS24Host.UNIVERSAL_ERROR_ACK;
        } else if (how == 1) {
            proof.receipt = keccak256(abi.encode("a forged packet", i));
        } else {
            _liveClient().setTimestamp(pkt.timeoutTimestamp);
        }
        try ctl.proveOutcome(pkt, proof) returns (T.Proven pr) {
            done = true;
            if (pr == T.Proven.Collision) ok["proveCollision"]++;
            else if (proof.receipt == bytes32(0)) ok["proveNonReceipt"]++;
            else ok["prove"]++;
        } catch {
            // already proven by the active client: still good
            T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
            done = rec.proven != T.Proven.None && rec.provenBy == address(_liveClient());
        }
        if (how == 2) _liveClient().setTimestamp(0);
    }

    /// @notice The action the truth calls for (the controls accept it only if the proof agrees).
    function _action(uint256 i) internal view returns (T.SettleItem memory it) {
        T.SendRecord memory rec = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence);
        it.sequence = packets[i].sequence;
        if (!ghost[i].delivered) {
            it.action = 1;
            it.amount = rec.amount - rec.refunded;
        } else if (rec.refunded != 0) {
            it.action = 4;
            it.amount = rec.refunded;
        } else {
            it.action = (rec.payment == T.Payment.Queued || rec.payment == T.Payment.Parked) ? 2 : 3;
        }
    }

    /// @notice Reconciles through IBCAdmin (kind 12, at most eight items each) the unsettled records of the retired
    /// clients and the forged receives on them; with `all` false, only what kind 13 waits for.
    function _reconcile(uint256 how, bool all) internal returns (bool done) {
        done = true;
        // the live client must be healthy to prove through
        _liveClient().setStatus(false, false);
        for (uint256 k = 0; k + 1 < clients.length; k++) {
            string memory c = clients[k];
            T.SettleItem[] memory items = new T.SettleItem[](8);
            uint256 n;
            (,, uint64 start,,) = ctl.clientRecon(c);
            for (uint256 i = 0; i < packets.length; i++) {
                if (keccak256(bytes(packets[i].sourceClient)) != keccak256(bytes(c))) continue;
                T.SendRecord memory rec = ctl.sendRecord(c, packets[i].sequence);
                if (rec.settlement != 0) continue;
                bool needed = rec.open || (rec.processedBlock != 0 && rec.processedIndex >= start);
                if (!all && !needed) continue;
                if (!_prove(i, how + i)) {
                    done = false;
                    continue;
                }
                items[n++] = _action(i);
                if (n == 8) {
                    done = _settleBatch(c, items, n) && done;
                    n = 0;
                }
            }
            for (uint256 j = 0; all && j < receives.length; j++) {
                Receive memory r = receives[j];
                if (!r.forged || keccak256(bytes(r.client)) != keccak256(bytes(c))) continue;
                if (ctl.lossBooked(c, r.sequence, 2)) continue;
                items[n++] = T.SettleItem(r.sequence, 5, r.amount);
                if (n == 8) {
                    done = _settleBatch(c, items, n) && done;
                    n = 0;
                }
            }
            if (n != 0) done = _settleBatch(c, items, n) && done;
        }
    }

    function _settleBatch(string memory c, T.SettleItem[] memory items, uint256 n) internal returns (bool done) {
        P.SettleItem[] memory p = new P.SettleItem[](n);
        for (uint256 i = 0; i < n; i++) {
            p[i] = P.SettleItem(items[i].sequence, items[i].action, items[i].amount);
        }
        done = _executeAll(_one(_decide(S.KIND_SETTLE, P.settle(c, p))));
        if (done) {
            for (uint256 i = 0; i < n; i++) {
                if (items[i].action != 5) settledCount[keccak256(abi.encode(c, items[i].sequence))]++;
            }
            ok["settle"] += n;
        }
    }

    function reconcile(uint256 how, bool all) external {
        calls++;
        if (_reconcile(how, all)) ok["reconcile"]++;
    }

    /// @notice Kind 13 through IBCAdmin, then its continuation until the route opens (or the reopening aborts).
    function _reopen() internal returns (bool) {
        if (!_executeAll(_one(_decide(S.KIND_REOPEN, P.reopen(_live()))))) return false;
        ok["reopen"]++;
        for (uint256 i = 0; i < 4 && ctl.routeReopening(_live()); i++) {
            try ctl.continueReopen(_live(), 16) {
                ok["continueReopen"]++;
            } catch { }
        }
        return !ctl.routeClosed(_live());
    }

    function reopen() external {
        calls++;
        _reopen();
    }

    function continueReopen() external {
        calls++;
        try ctl.continueReopen(_live(), 16) {
            ok["continueReopen"]++;
        } catch { }
    }

    /// @notice Forged refunds paid on seventeen tokens, a replacement and its reconciliation: a kind 13 whose deficits
    /// need more than one batch, left reopening.
    function _startLongReopening() internal returns (bool) {
        if (ctl.routeReopening(_live())) return true;
        // the forged refunds must be paid (no refunds hold): every guardian clears its own flag
        for (uint256 g = 0; g < 4; g++) {
            vm.prank(G[g]);
            try ctl.clearRefundsFlag(_live()) { } catch { }
        }
        // from an open route: a closed one is reconciled and reopened first
        if (ctl.routeClosed(_live()) && (!_reconcile(0, true) || !_reopen())) return false;
        {
            if (clients.length >= 40) return false;
            for (uint256 t = 1; t <= 17; t++) {
                if (!_send(alice, tokens[t], 1, true)) return false;
                uint256 i = packets.length - 1;
                try router.ackPacket(
                    IICS26RouterMsgs.MsgAckPacket(
                        packets[i], ICS24Host.UNIVERSAL_ERROR_ACK, "", IICS02ClientMsgs.Height(0, 1)
                    )
                ) {
                    ghost[i].relayed = true;
                    ghost[i].forgedRefund = true;
                } catch { }
            }
            if (!_replace(true)) return false;
        }
        if (!_reconcile(0, true)) return false;
        if (!_executeAll(_one(_decide(S.KIND_REOPEN, P.reopen(_live()))))) return false;
        ok["reopen"]++;
        return ctl.routeReopening(_live());
    }

    /// @notice A replacement while a reopening is under way: it aborts the reopening.
    function replaceDuringReopening() external {
        calls++;
        if (clients.length >= 40 || !_startLongReopening()) return;
        if (_replace(true) && !ctl.routeReopening(_live())) ok["replaceDuringReopening"]++;
    }

    /// @notice A packet sent before the fork (the router holds it, no record) backfilled on a retired id during a
    /// reopening: the last batch finds it open and aborts the reopening.
    function backfillDuringReopening(uint256 amount) external {
        calls++;
        if (!_startLongReopening()) return;
        amount = bound(amount, 1, 10);
        string memory retired = clients[clients.length - 2];
        IICS26RouterMsgs.Payload memory pl = IICS26RouterMsgs.Payload(
            ICS20Lib.DEFAULT_PORT_ID,
            ICS20Lib.DEFAULT_PORT_ID,
            ICS20Lib.ICS20_VERSION,
            ICS20Lib.ICS20_ENCODING,
            abi.encode(
                IICS20TransferMsgs.FungibleTokenPacketData({
                    denom: Strings.toHexString(tokens[0]),
                    sender: Strings.toHexString(alice),
                    receiver: "g1receiver",
                    amount: amount,
                    memo: ""
                })
            )
        );
        uint64 timeout = uint64(_now() + 600);
        uint64 seq;
        // a send made before the fork: its tokens are in the route's escrow, the router holds its commitment
        ERC20Mock(tokens[0]).mint(ics20.getEscrow(clients[0]), amount);
        vm.prank(address(ics20));
        try router.sendPacket(IICS26RouterMsgs.MsgSendPacket(retired, timeout, pl)) returns (uint64 s) {
            seq = s;
        } catch {
            return;
        }
        IICS26RouterMsgs.Payload[] memory pls = new IICS26RouterMsgs.Payload[](1);
        pls[0] = pl;
        IICS26RouterMsgs.Packet memory pkt =
            IICS26RouterMsgs.Packet(seq, retired, router.getCounterparty(retired).clientId, timeout, pls);
        try ctl.backfill(pkt) {
            packets.push(pkt);
            ghost[packets.length - 1] = Ghost(false, false, false, true, alice); // never received: refundable
            ok["backfill"]++;
        } catch {
            return;
        }
        for (uint256 i = 0; i < 4 && ctl.routeReopening(_live()); i++) {
            try ctl.continueReopen(_live(), 16) { } catch { }
        }
        if (!ctl.routeReopening(_live()) && ctl.routeClosed(_live())) ok["abortAfterBackfill"]++;
    }

    /// @notice A loss found after the route reopened: kind 12 on a remaining record of a resolved incident (or a
    /// forged receive) closes the route again; a new kind 13 accepts it.
    function lateLoss(uint256 how) external {
        calls++;
        if (ctl.routeClosed(_live())) return;
        if (_reconcile(how, true) && ctl.routeClosed(_live())) {
            ok["lateLoss"]++;
            _reopen();
        }
    }

    function warp(uint256 dt) external {
        calls++;
        _skip(bound(dt, 1, 2 days));
    }

    /// @notice The route open again: a reopening under way continued, a closed route reconciled and reopened.
    function _ensureOpen() internal returns (bool) {
        for (uint256 i = 0; i < 4 && ctl.routeReopening(_live()); i++) {
            try ctl.continueReopen(_live(), 16) {
                ok["continueReopen"]++;
            } catch { }
        }
        if (ctl.routeClosed(_live()) && !ctl.routeReopening(_live())) {
            _reconcile(0, true);
            _reopen();
        }
        for (uint256 g = 0; g < 4; g++) {
            vm.prank(G[g]);
            try ctl.clearRefundsFlag(_live()) { } catch { }
        }
        _liveClient().setStatus(false, false);
        return !ctl.routeClosed(_live());
    }

    /// @notice Ordinary traffic on an open route: sends of random truth relayed honestly or forged, a queued
    /// refund claimed, a refused refund parked and claimed, honest and forged receives.
    function transportRound(uint256 seed) public {
        calls++;
        if (!_ensureOpen()) return;
        for (uint256 k = 0; k < 4; k++) {
            if (!_send(alice, tokens[0], 20, (seed >> k) & 1 == 1)) return;
            this.relay(packets.length - 1, (seed >> (k + 8)) & 1 == 1, (seed >> (k + 16)) & 1 == 1);
        }
        _skip(1 days);
        this.claim(0);
        this.claim(tokens.length - 1); // nothing queued ahead of the next hook-token refund
        if (_send(alice, address(hookToken), 5, false)) {
            uint256 i = packets.length - 1;
            hookToken.setBlocked(alice, true);
            this.relay(i, false, false); // refused by the token: parked
            hookToken.setBlocked(alice, false);
            this.claimParked(i);
        }
        // a delivered send's escrow (its vouchers on gno.land) backs the receives
        if (_send(alice, tokens[0], 30, true)) this.relay(packets.length - 1, false, false);
        this.receive_(0, 5, false);
        this.receive_(0, 3, true);
        ok["transportRound"]++;
    }

    /// @notice A forged refund processed before the next replacement's suspected interval is left by the
    /// reconciliation kind 13 needs; settled after the reopening, its loss closes the route again (a late loss), and
    /// a new kind 13 accepts it.
    function lateLossScenario() public {
        calls++;
        if (clients.length >= 40 || !_ensureOpen()) return;
        if (!_send(alice, tokens[1], 10, true)) return;
        this.relay(packets.length - 1, true, false); // a forged error ack: refunded at once
        _skip(1 days);
        if (!_replace(false)) return; // its interval starts after the forged refund
        _reconcile(0, false);
        if (!_reopen()) return;
        if (_reconcile(1, true) && ctl.routeClosed(_live())) {
            ok["lateLoss"]++;
            _reopen();
        }
    }

    // ----------------------------------------------------------------------------------- coverage sweep --

    /// @notice Runs each required composite once after the random sequence when the sequence did not.
    function sweep() external {
        if (ok["transportRound"] == 0) transportRound(0xA5A5A5);
        if (ok["lateLoss"] == 0) lateLossScenario();
        if (ok["replace"] == 0 && clients.length < 6 && _replace(true)) ok["replace"]++;
        if (ok["reconcile"] == 0 && _reconcile(0, true)) ok["reconcile"]++;
        if (ctl.routeClosed(_live()) && !ctl.routeReopening(_live())) _reopen();
        if (ok["busyGovernance"] == 0 && !ctl.routeClosed(_live())) this.busyGovernance(3);
        if (ok["replaceDuringReopening"] == 0) this.replaceDuringReopening();
        if (ok["abortAfterBackfill"] == 0) this.backfillDuringReopening(5);
        // the aborted reopening reconciled and reopened again: its deficits need the continuation
        if (ctl.routeClosed(_live()) && !ctl.routeReopening(_live())) {
            _reconcile(0, true);
            _reopen();
        }
        for (uint256 i = 0; i < 4 && ctl.routeReopening(_live()); i++) {
            try ctl.continueReopen(_live(), 16) {
                ok["continueReopen"]++;
            } catch { }
        }
    }
}

/// @notice Invariants of the reconciliation state machine (docs/controls.md) against the ghost model.
contract ReconcileInvariantsTest is ControlsFixture {
    ReconcileHandler internal h;

    function _recovery() internal pure override returns (IIBCAdmin.RecoveryConfig memory) {
        return IIBCAdmin.RecoveryConfig({
            delay: 30 days, threshold: 3, cancelThreshold: 3, silence: 30 days, holdPeriod: 14 days
        });
    }

    function setUp() public override {
        super.setUp();
        h = new ReconcileHandler(router, ctl, ics20, admin, alice, bob, G, clientId, address(usdc));
        vm.prank(alice);
        usdc.approve(address(ics20), type(uint256).max);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = ReconcileHandler.sweep.selector;
        excludeSelector(FuzzSelector(address(h), sel));
    }

    function _reserveOf(T.SendRecord memory rec) internal pure returns (uint256) {
        if (rec.burned) return 0;
        if (rec.payment == T.Payment.Queued || rec.payment == T.Payment.Parked) return rec.amount - rec.refunded;
        return rec.outcome == T.Outcome.Pending && rec.settlement == 0 ? rec.amount : 0;
    }

    function _resolved(string memory client) internal view returns (bool) {
        (, uint32 incident,,,) = ctl.clientRecon(client);
        (, uint64 resolvedUpTo,) = ctl.incidents(clientId);
        return incident != 0 && incident - 1 < resolvedUpTo;
    }

    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 40
    function invariant_ghostModel() public view {
        _checkAll();
    }

    function _checkAll() internal view {
        uint256 n = h.packetCount();
        uint256 tn = h.tokenCount();
        bool open = !ctl.routeClosed(clientId);
        uint256[] memory reserve = new uint256[](tn);
        uint256[] memory shortfall = new uint256[](tn);
        for (uint256 i = 0; i < n; i++) {
            IICS26RouterMsgs.Packet memory pkt = h.packet(i);
            T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
            (bool delivered, bool forgedSuccess,,,) = h.ghost(i);
            uint256 t;
            while (t < tn && h.tokens(t) != rec.token) t++;
            uint256 r = _reserveOf(rec);
            reserve[t] += r;
            // every record settled at most once, never refunded beyond its amount
            assertLe(h.settledCount(keccak256(abi.encode(pkt.sourceClient, pkt.sequence))), 1, "settled once");
            assertLe(rec.refunded, rec.amount, "refunded once");
            // kind 12's actions agree with the truth (the proofs are honest)
            if (rec.settlement == 1) assertFalse(delivered, "a refund settled for a delivered packet");
            if (rec.settlement >= 2) assertTrue(delivered, "a delivered settlement for an undelivered packet");
            // an undelivered record ends refunded in full or still reserved, unless a forged success ack hides it
            // until its incident's reconciliation
            if (!delivered && rec.refunded != rec.amount && r != rec.amount - rec.refunded) {
                assertTrue(
                    rec.outcome == T.Outcome.Success && rec.settlement == 0 && !_resolved(pkt.sourceClient),
                    "an undelivered refund neither paid nor reserved"
                );
            }
            // the outstanding shortfall a forged success ack left: owed by reconciliation, still unpaid
            if (forgedSuccess && rec.settlement == 1) shortfall[t] += r;
            // a refund paid for a delivered packet is a recognized loss once its incident resolved
            if (open && delivered && rec.refunded != 0 && _resolved(pkt.sourceClient)) {
                assertTrue(ctl.lossBooked(pkt.sourceClient, pkt.sequence, 1), "a forged refund not booked");
            }
        }
        address escrow = ics20.getEscrow(clientId);
        for (uint256 t = 0; t < tn; t++) {
            address token = h.tokens(t);
            uint256 reserved = ctl.reserved(clientId, token);
            // the reservation equals the records' outstanding entitlements (no backing lost or invented)
            assertEq(reserved, reserve[t], "reservation equals the entitlements");
            // and the escrow covers it, but for the unpaid shortfalls of forged success acks
            assertGe(IERC20(token).balanceOf(escrow) + shortfall[t], reserved, "escrow covers the reservation");
            if (open) assertEq(ctl.losses(clientId, token), ctl.acceptedDeficit(clientId, token), "losses accepted");
        }
        uint256 m = h.receiveCount();
        for (uint256 j = 0; j < m && open; j++) {
            ReconcileHandler.Receive memory rv = h.receiveAt(j);
            if (rv.forged && _resolved(rv.client)) {
                assertTrue(ctl.lossBooked(rv.client, rv.sequence, 2), "a forged receive not booked");
            }
        }
        _checkCounters(n);
    }

    function _checkCounters(uint256 n) internal view {
        (T.Incident[] memory inc, uint64 resolved, uint64 pending) = ctl.incidents(clientId);
        uint256 m = h.clientCount();
        bool closed = ctl.routeClosed(clientId);
        uint64 p;
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
            if (incident != 0 && incident - 1 >= resolved && (open != 0 || suspect != 0)) p++;
            if (!closed && k + 1 < m) {
                assertEq(open, 0, "a retired client's record open on an open route");
                assertEq(suspect, 0, "a retired client's suspect record on an open route");
            }
        }
        assertEq(pending, p, "pending incidents");
        if (!closed) assertEq(resolved, inc.length, "open only when every incident resolved");
        for (uint256 i = 0; i < inc.length; i++) {
            assertEq(inc[i].status == 3, i < resolved, "resolved exactly below resolvedUpTo");
        }
    }

    /// @notice After each run: the required composites covered (run by the sweep if the sequence did not), the
    /// invariants checked again, and the run's per-action counts reported.
    function afterInvariant() external {
        h.sweep();
        _checkAll();
        string[28] memory names = [
            "send",
            "sendFromAdapter",
            "relayHonest",
            "relayForged",
            "receiveHonest",
            "receiveForged",
            "claim",
            "claimParked",
            "refundsFlag",
            "notify",
            "busyGovernance",
            "verifierFreeze",
            "verifierExpire",
            "verifierMigrate",
            "replace",
            "recover",
            "prove",
            "proveCollision",
            "proveNonReceipt",
            "settle",
            "reconcile",
            "reopen",
            "continueReopen",
            "replaceDuringReopening",
            "backfill",
            "abortAfterBackfill",
            "lateLoss",
            "transportRound"
        ];
        string memory line = "ACTIONS";
        for (uint256 i = 0; i < names.length; i++) {
            line = string.concat(line, " ", names[i], "=", vm.toString(h.ok(names[i])));
        }
        console2.log(line);
        string[13] memory required = [
            "reconcile",
            "reopen",
            "continueReopen",
            "replaceDuringReopening",
            "backfill",
            "abortAfterBackfill",
            "lateLoss",
            "transportRound",
            "relayHonest",
            "relayForged",
            "claimParked",
            "receiveForged",
            "settle"
        ];
        for (uint256 i = 0; i < required.length; i++) {
            assertGe(h.ok(required[i]), 1, required[i]);
        }
    }
}
