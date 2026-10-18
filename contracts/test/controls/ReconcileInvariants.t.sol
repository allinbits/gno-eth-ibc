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
import { IICS26RouterErrors } from "@eureka/errors/IICS26RouterErrors.sol";
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
import { HookToken, SenderAdapter, ReentrantSender } from "../utils/ControlsMocks.sol";
import { GnoVoucher } from "../../src/GnoVoucher.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Called from a token hook inside a send (the transfer app busy, the router free): a governance delivery
/// (reverted whole: the router reports `IBCFailedCallback` and writes nothing) and a drain with a decision buffered
/// (nothing recorded).
contract BusyProbe {
    ICS26Router internal immutable router;
    IBCAdmin internal immutable admin;
    uint256 public drained = type(uint256).max;
    uint64 public lastSeqSeen;

    constructor(ICS26Router r, IBCAdmin a) {
        (router, admin) = (r, a);
    }

    bool public deliveryReverted;

    function probe(IICS26RouterMsgs.Packet calldata gov) external {
        try router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(gov, "", IICS02ClientMsgs.Height(0, 1))) { }
        catch (bytes memory r) {
            deliveryReverted = r.length >= 4 && bytes4(r) == IICS26RouterErrors.IBCFailedCallback.selector;
        }
        drained = admin.drain();
        lastSeqSeen = admin.lastSeq();
    }
}

/// @notice The ghost model and the actions of the invariant campaign. Every packet's truth (delivered or not) is
/// chosen when it is sent; relays are honest or forged against it; proofs are honest (through the active client):
/// every refund, reservation, settlement and loss is checked against the truth, independently of the controls'
/// own bookkeeping. Governance (kinds 6, 10, 12, 13) runs through IBCAdmin.execute.
/// @notice The test contract's invariant check, run by the handler between the steps of a composite transition.
interface ICheckpoint {
    function checkpoint() external view;
}

contract ReconcileHandler is Test {
    ICheckpoint internal checker;
    // forged receives governance deliberately leaves out of its reconciliation (index + 1 => true): booked later as
    // late losses, the only departure from the complete-reconciliation precondition, and a deliberate one
    mapping(uint256 => bool) public leftOut;
    mapping(uint256 => bool) public leftOutSend; // the same for send records (packet index + 1)

    ICS26Router internal router;
    IGnoICS20Controls internal ctl;
    GnoICS20Transfer internal ics20;
    IBCAdmin internal admin;
    address internal alice;
    address internal bob;
    address[4] internal G;
    BusyProbe internal busyProbe;
    SenderAdapter internal adapter;

    address[] public tokens; // usdc first; LOSS_TOKENS more (deficits over several batches); the partial-backing
    // token; the hook token last
    uint256 internal constant LOSS_TOKENS = 33;
    address public partialToken; // only `partialBacking` sends it
    address public twinToken; // only `twinEligibleRefunds` sends it
    address public twinInitialToken; // only `twinHiddenInitial` sends it
    address public voidToken; // only `voidAndReprove` sends it
    address public deliveredToken; // only `deliveredVoidSibling` sends it
    // each record's refund paid as of the last step's start: a record paid since must have left every other
    // record's reservation backed (the payment's own postcondition)
    mapping(uint256 => uint256) public refundedAt;
    // the permitted shortfall per token: what reconciliation recognized as compromise losses (the refunds a forged
    // success ack hid, owed again), never raised by a receive or a payment, lowered as the escrow covers it again
    mapping(address => uint256) public permittedShortfall;
    // the epochs whose notice a switched (or duplicate) ack reached
    mapping(uint32 => bool) internal noticeAckedGhost;
    // the refunds that allowance belongs to (packet index => true): a forged success ack hid them, kind 12 owes them
    // again; the allowance is never more than what of them is still unpaid
    mapping(uint256 => bool) public eligible;
    // the ghost's own record of a proof that a packet's refund is owed (it was not delivered, and the handler proved
    // that through the active verifier): from then on its reservation is held, until settled (ADR §7.12)
    mapping(uint256 => bool) public provenOwed;
    // the ghost's record of a proof that a packet was delivered (it releases a held success)
    mapping(uint256 => bool) public provenDelivered;
    // a success processed on a client already retired (held at once), and the retired clients whose suspect
    // successes the handler's preparation reserved
    mapping(uint256 => bool) public relayedRetired;
    mapping(bytes32 => bool) public preparedGhost;
    // the ghost's own processed list of each client (packet indices, in processing order) and its preparation
    // cursor, and the records a preparation batch visited (held from then on unless settled before)
    mapping(bytes32 => uint256[]) internal processedOf;
    mapping(bytes32 => uint256) public prepCursorOf;
    mapping(uint256 => bool) public prepVisited;
    // the action governance settled each record with (0: not settled)
    mapping(bytes32 => uint8) public settledAction;
    mapping(uint256 => bool) public ignoredRelay; // relayed after its settlement: ignored by the controls
    bool internal partialDone; // after its scenario, ordinary sends may use the partial-backing token
    uint256 internal contSeed;
    HookToken internal hookToken;
    mapping(address => bool) internal limited;

    struct Ghost {
        bool delivered; // the destination's truth
        bool forgedSuccess; // a success ack relayed for an undelivered packet
        bool forgedRefund; // an error ack or timeout relayed for a delivered packet
        bool relayed; // acked or timed out at the router
        address sender;
        address token; // what the handler sent, independently of the controls' record
        uint256 amount;
    }

    IICS26RouterMsgs.Packet[] internal packets;
    mapping(uint256 => Ghost) public ghost;
    // the client id each send named (the handler's own input, never read back from the packet)
    mapping(uint256 => string) public sentOver;
    mapping(bytes32 => uint256) public settledCount;
    // the ghost transport history: the block each packet's ack or timeout was processed in (0: never)
    mapping(uint256 => uint256) public relayBlock;
    // the ghost incident boundaries: each client id the handler's replacements retired, and the block its suspect
    // interval starts at (the replacement's `suspectFrom`)
    mapping(bytes32 => bool) public retiredGhost;
    mapping(bytes32 => uint64) public suspectFromOf;

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

    // token movements, tracked independently of the controls' records
    mapping(address => mapping(address => uint256)) public sentBy; // sender => token => amount escrowed by sends
    mapping(address => uint256) public received; // token => amount released or minted to bob by receives
    mapping(address => uint256) public initialAlice; // token => alice's balance when the campaign starts
    // what the handler minted to each contract sender, per (sender, token)
    mapping(address => mapping(address => uint256)) public minted;
    ReentrantSender public reentrant;
    GnoVoucher public ugnot;
    uint256 public ugnotSupply0;

    // invariant 7: the losses when the current reopening started (they never change while it runs)
    mapping(address => uint256) public lossSnapshot;
    string public snapshotClient; // the route whose reopening the snapshot belongs to
    uint256 internal nonce;
    uint256 internal heldBack; // 1 + the index of a forged receive governance leaves out of its reconciliation //
    // unique client ids for the split steps and the recovery attempts
    uint64[] internal pending; // decisions recorded by the split actions, executed by executePending

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
        for (uint256 i = 0; i <= LOSS_TOKENS + 4; i++) {
            ERC20Mock t = new ERC20Mock();
            t.mint(alice, 1e30);
            tokens.push(address(t));
        }
        partialToken = tokens[LOSS_TOKENS + 1];
        twinToken = tokens[LOSS_TOKENS + 2];
        twinInitialToken = tokens[LOSS_TOKENS + 3];
        voidToken = tokens[LOSS_TOKENS + 4];
        deliveredToken = tokens[LOSS_TOKENS + 5];
        hookToken = new HookToken();
        hookToken.mint(alice, 1e30);
        tokens.push(address(hookToken));
        for (uint256 i = 0; i < tokens.length; i++) {
            vm.prank(alice);
            IERC20(tokens[i]).approve(address(ics20), type(uint256).max);
        }
        busyProbe = new BusyProbe(router, admin);
        adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(usdc), address(0xADA));
        // its own token, so no refund queued in another sender's token delays its callback
        reentrant = new ReentrantSender(IICS20Transfer(address(ics20)), IERC20(tokens[2]));
        for (uint256 i = 0; i < tokens.length; i++) {
            initialAlice[tokens[i]] = IERC20(tokens[i]).balanceOf(alice_);
        }
    }

    // ------------------------------------------------------------------------------------------------ views --

    function adapterAddress() external view returns (address) {
        return address(adapter);
    }

    /// @notice How far the route's escrow of `token` falls short of its reservation now.
    function uncovered(address token) public view returns (uint256) {
        address escrow = ics20.getEscrow(clients[0]);
        if (escrow == address(0)) return 0;
        uint256 reserved = ctl.reserved(clients[0], token);
        uint256 bal = IERC20(token).balanceOf(escrow);
        return reserved > bal ? reserved - bal : 0;
    }

    /// @notice The permitted shortfall never exceeds what is uncovered now: covered again, it is no longer
    /// permitted. Run at the start of every step that could move escrow.
    function _ratchet() internal {
        for (uint256 t = 0; t < tokens.length; t++) {
            uint256 u = uncovered(tokens[t]);
            if (permittedShortfall[tokens[t]] > u) permittedShortfall[tokens[t]] = u;
        }
        for (uint256 i = 0; i < packets.length; i++) {
            refundedAt[i] = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence).refunded;
        }
    }

    /// @notice The ghost's transport history: packet `i`'s ack or timeout processed now.
    function _relayed(uint256 i) internal {
        ghost[i].relayed = true;
        relayBlock[i] = vm.getBlockNumber();
        // processed (an ack or timeout of a settled record is ignored, not processed)
        if (settledCount[keccak256(abi.encode(packets[i].sourceClient, packets[i].sequence))] == 0) {
            processedOf[keccak256(bytes(packets[i].sourceClient))].push(i);
        } else {
            ignoredRelay[i] = true;
        }
        if (retiredGhost[keccak256(bytes(packets[i].sourceClient))]) {
            relayedRetired[i] = true;
            _eligibleIfHeld(i);
        }
    }

    /// @notice Whether packet `i`'s success is held as a potential refund, from the ghost alone: unsettled, relayed
    /// with a success (a proof of delivery releases nothing; only the settlement), and either proven owed, processed on
    /// a client already retired, or in the suspect interval of a client whose incident the handler prepared.
    /// @notice Whether every retired client's incident is prepared (the ghost's): kind 12 may pay only then.
    function allPrepared() public view returns (bool) {
        for (uint256 k = 0; k + 1 < clients.length; k++) {
            if (!preparedGhost[keccak256(bytes(clients[k]))]) return false;
        }
        return true;
    }

    function heldGhost(uint256 i) public view returns (bool) {
        Ghost memory gh = ghost[i];
        bool success = gh.relayed && (gh.forgedSuccess || (gh.delivered && !gh.forgedRefund));
        if (!success) return false;
        if (settledCount[keccak256(abi.encode(packets[i].sourceClient, packets[i].sequence))] != 0) return false;
        bytes32 ch = keccak256(bytes(packets[i].sourceClient));
        ch;
        return provenOwed[i] || relayedRetired[i] || prepVisited[i];
    }

    /// @notice A held success is a recognized compromise liability: its shortfall is permitted (lowered at every step).
    function _eligibleIfHeld(uint256 i) internal {
        if (!eligible[i] && heldGhost(i)) {
            eligible[i] = true;
            permittedShortfall[ghost[i].token] += ghost[i].amount;
        }
    }

    /// @notice The incident of retired client `c` prepared, in batches of `n` (all of it when `n` is large).
    function _prepare(string memory c, uint256 n) internal returns (bool done) {
        bytes32 ch = keccak256(bytes(c));
        uint256 left;
        try ctl.prepareIncident(c, n) returns (uint256 l) {
            left = l;
        } catch {
            return false;
        }
        if (preparedGhost[ch]) return left == 0;
        // the ghost's own batch: the next `n` records of its processed list from its cursor, each unsettled success
        // held from now on
        uint256[] storage list = processedOf[ch];
        uint256 cur = prepCursorOf[ch];
        uint256 stop = cur + n < list.length ? cur + n : list.length;
        for (; cur < stop; cur++) {
            uint256 i = list[cur];
            Ghost memory gh = ghost[i];
            bool success = gh.forgedSuccess || (gh.delivered && !gh.forgedRefund);
            if (success && settledCount[keccak256(abi.encode(packets[i].sourceClient, packets[i].sequence))] == 0) {
                prepVisited[i] = true;
                _eligibleIfHeld(i);
            }
        }
        prepCursorOf[ch] = cur;
        assertEq(left, list.length - cur, "preparation left (the ghost's cursor)");
        done = left == 0;
        if (done) {
            preparedGhost[ch] = true;
            ok["prepared"]++;
        } else if (n != 0) {
            ok["preparePartial"]++;
        }
    }

    /// @notice A preparation step of a random retired client (possibly partial).
    function prepareStep(uint256 seed) external {
        calls++;
        _ratchet();
        if (clients.length < 2) return;
        _prepare(clients[seed % (clients.length - 1)], 1 + (seed >> 8) % 4);
        _checkpoint();
    }

    /// @notice Proves one retired record and settles it at once, alone, whatever else is prepared or proven: arbitrary
    /// interleavings of proofs and payments.
    function proveAndPay(uint256 i, uint256 how) external {
        calls++;
        _ratchet();
        if (packets.length == 0) return;
        i = i % packets.length;
        if (!ctl.isRetired(packets[i].sourceClient)) return;
        T.SendRecord memory rec = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence);
        if (rec.settlement != 0 || !_prove(i, how % 3)) return;
        T.SettleItem[] memory items = new T.SettleItem[](1);
        items[0] = _action(i);
        if (_settleBatch(packets[i].sourceClient, items, 1)) ok["proveAndPay"]++;
    }

    /// @notice The ghost's incident boundary: the live client retired by a replacement whose suspect interval starts
    /// at `suspectFrom`, and `next` live.
    function _retire(string memory next, uint64 suspectFrom) internal {
        bytes32 old = keccak256(bytes(clients[clients.length - 1]));
        retiredGhost[old] = true;
        suspectFromOf[old] = suspectFrom;
        // the preparation starts at the first record processed at or after `suspectFrom` (the ghost's own list)
        uint256[] storage list = processedOf[old];
        uint256 start = 0;
        while (start < list.length && relayBlock[list[start]] < suspectFrom) start++;
        prepCursorOf[old] = start;
        // nothing processed in its suspect interval: its incident needs no preparation
        if (start == list.length) preparedGhost[old] = true;
        clients.push(next);
    }

    /// @notice The work a client id still has, derived from the ghost alone (never from the controls' records or
    /// counters): its records still open (the commitment outstanding, or a refund owed and not paid in full) and,
    /// once retired, its suspect ones (processed at or after its suspect interval's start, not settled).
    function expectedWork(string memory c) public view returns (uint64 open, uint64 suspect) {
        bytes32 ch = keccak256(bytes(c));
        for (uint256 i = 0; i < packets.length; i++) {
            if (keccak256(bytes(packets[i].sourceClient)) != ch) continue;
            (bool o, bool sus) = expectedOf(i);
            if (o) open++;
            if (sus) suspect++;
        }
    }

    /// @notice Packet `i`'s expected state from the ghost: open, and suspect.
    function expectedOf(uint256 i) public view returns (bool open, bool suspect) {
        Ghost memory gh = ghost[i];
        bool settled = settledCount[keccak256(abi.encode(packets[i].sourceClient, packets[i].sequence))] != 0;
        bool refundOutcome = gh.relayed && (gh.delivered ? gh.forgedRefund : !gh.forgedSuccess);
        // the refund actually paid, which the token balances check independently (payment conservation)
        uint256 refunded = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence).refunded;
        open = !settled && (!gh.relayed || (refundOutcome && refunded < gh.amount));
        bytes32 ch = keccak256(bytes(packets[i].sourceClient));
        suspect = !settled && retiredGhost[ch] && gh.relayed && relayBlock[i] >= suspectFromOf[ch];
    }

    function setChecker(ICheckpoint c) external {
        checker = c;
    }

    /// @notice The invariants, between two steps of a composite transition.
    function _checkpoint() internal {
        if (address(checker) != address(0)) checker.checkpoint();
        _ratchet();
    }

    /// @notice Test-only (excluded from the fuzzed selectors): replaces packet `i` as the handler saw it, for the
    /// binding corruption probes.
    function probeSetPacket(uint256 i, IICS26RouterMsgs.Packet memory pkt) external {
        packets[i] = pkt;
    }

    function setVoucher(GnoVoucher v) external {
        ugnot = v;
        ugnotSupply0 = v.totalSupply();
        vm.prank(bob);
        v.approve(address(ics20), type(uint256).max);
    }

    /// @notice Right after a kind 13 executed (a new reopening started): the losses at its start, which invariant 7
    /// compares while it runs. Never taken at any other moment.
    function _snapshotNew() internal {
        if (!ctl.routeReopening(_live())) return;
        for (uint256 t = 0; t < tokens.length; t++) {
            lossSnapshot[tokens[t]] = ctl.losses(_live(), tokens[t]);
        }
        lossSnapshot[address(ugnot)] = ctl.losses(_live(), address(ugnot));
        snapshotClient = _live();
    }

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

    function liveClientId() external view returns (string memory) {
        return _live();
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
        // anything left buffered is recorded first, so the next number is free
        while (admin.drain() != 0) { }
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
            IIBCAdmin.Decision memory dec = admin.decision(ep, seqs[i]); // its parameters, before they are cleared
            try admin.execute(seqs[i]) { } catch { }
            if (!_noteExecuted(ep, seqs[i], dec)) all = false;
        }
        _checkpoint();
    }

    /// @notice The ghost follows governance's own executed decisions (what it decided, never the records): a kind 12
    /// settles its items (forged receives aside), a kind 10 of the live client retires it with its suspect interval,
    /// a kind 13 starts a reopening (the losses snapshot). `dec`: the decision as recorded, read before it executed
    /// (execution may clear its parameters). Whether `seq` executed.
    function _noteExecuted(uint32 ep, uint64 seq, IIBCAdmin.Decision memory dec) internal returns (bool) {
        if (admin.decision(ep, seq).state != S.EXECUTED) return false;
        if (dec.kind == S.KIND_SETTLE) {
            (string memory c, T.SettleItem[] memory items) = abi.decode(dec.params, (string, T.SettleItem[]));
            for (uint256 k = 0; k < items.length; k++) {
                if (items[k].action != 5) {
                    settledCount[keccak256(abi.encode(c, items[k].sequence))]++;
                    settledAction[keccak256(abi.encode(c, items[k].sequence))] = items[k].action;
                }
                // a refund a forged success ack hid, owed again: the compromise loss reconciliation recognizes
                if (items[k].action == 1) {
                    uint256 j = _packetIndex(c, items[k].sequence);
                    if (ghost[j].forgedSuccess && !eligible[j]) {
                        permittedShortfall[ghost[j].token] += items[k].amount;
                        eligible[j] = true;
                    }
                }
            }
        } else if (dec.kind == S.KIND_ROUTE) {
            (string memory old, string memory next, uint64 from) = abi.decode(dec.params, (string, string, uint64));
            if (keccak256(bytes(old)) == keccak256(bytes(_live()))) _retire(next, from);
        } else if (dec.kind == S.KIND_REOPEN) {
            _snapshotNew();
        }
        return true;
    }

    function _packetIndex(string memory c, uint64 seq) internal view returns (uint256) {
        bytes32 ch = keccak256(bytes(c));
        for (uint256 i = 0; i < packets.length; i++) {
            if (packets[i].sequence == seq && keccak256(bytes(packets[i].sourceClient)) == ch) return i;
        }
        revert("no such packet");
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
                ghost[packets.length - 1] = Ghost(delivered, false, false, false, from, token, amount);
                sentOver[packets.length - 1] = _live();
                if (delivered) redeemable[token] += amount;
                sentBy[from][token] += amount;
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
        _ratchet();
        address token = _pick(tokenSeed);
        if (_send(alice, token, bound(amount, 1, 100), delivered)) ok["send"]++;
    }

    /// @notice A contract sender (notified through IIBCSenderCallbacks; it takes callbacks only from ICS20).
    function sendFromAdapter(uint256 amount, bool delivered) external {
        calls++;
        _ratchet();
        amount = bound(amount, 1, 100);
        ERC20Mock(tokens[0]).mint(address(adapter), amount);
        minted[address(adapter)][tokens[0]] += amount;
        _limits(tokens[0]);
        vm.recordLogs();
        try adapter.send(amount, _live()) {
            if (_record(delivered, address(adapter), tokens[0], amount)) ok["sendFromAdapter"]++;
        } catch { }
    }

    /// @notice Relays a packet's outcome, honestly or forged against its truth.
    function relay(uint256 i, bool forged, bool useTimeout) external {
        calls++;
        _ratchet();
        if (packets.length == 0) return;
        i = bound(i, 0, packets.length - 1);
        if (ghost[i].relayed) return;
        IICS26RouterMsgs.Packet memory pkt = packets[i];
        bool success = ghost[i].delivered != forged;
        bool done;
        if (success) {
            // a success ack's bytes vary (any non-error ack is a success): the proven ack may differ from the relayed
            bytes memory okAck = useTimeout ? bytes("{\"result\":\"Zm9yZ2Vk\"}") : bytes("{\"result\":\"AQ==\"}");
            try router.ackPacket(IICS26RouterMsgs.MsgAckPacket(pkt, okAck, "", IICS02ClientMsgs.Height(0, 1))) {
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
        _relayed(i);
        if (forged && success) ghost[i].forgedSuccess = true;
        if (forged && !success) ghost[i].forgedRefund = true;
        ok[forged ? "relayForged" : "relayHonest"]++;
    }

    /// @notice A receive returning a token to bob: honest (vouchers of a delivered send) or forged.
    function receive_(uint256 tokenSeed, uint256 amount, bool forged) external {
        calls++;
        _ratchet();
        address token = _pick(tokenSeed);
        amount = bound(amount, 1, 50);
        if (!forged && redeemable[token] < amount) return;
        _receiveToken(token, amount, forged);
    }

    /// @notice A random token, never the partial-backing one.
    function _pick(uint256 seed) internal view returns (address token) {
        token = tokens[seed % 2 == 0 ? 0 : bound(seed, 0, tokens.length - 1)];
        if (
            (token == partialToken && !partialDone) || token == twinToken || token == twinInitialToken
                || token == voidToken || token == deliveredToken
        ) {
            token = tokens[0];
        }
    }

    /// @notice A receive of `amount` of `token` to bob over the live client; whether it was received.
    function _receiveToken(address token, uint256 amount, bool forged) internal returns (bool done) {
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
                received[token] += got;
                if (!forged) redeemable[token] -= amount;
                ok[forged ? "receiveForged" : "receiveHonest"]++;
                done = true;
            }
        } catch { }
    }

    function claim(uint256 tokenSeed) external {
        calls++;
        _ratchet();
        try ctl.claim(_live(), tokens[bound(tokenSeed, 0, tokens.length - 1)], 5) returns (uint256 n) {
            if (n != 0) ok["claim"]++;
        } catch { }
    }

    function claimParked(uint256 i) external {
        calls++;
        _ratchet();
        if (packets.length == 0) return;
        IICS26RouterMsgs.Packet memory pkt = packets[bound(i, 0, packets.length - 1)];
        try ctl.claimParked(pkt.sourceClient, pkt.sequence, 300_000) {
            ok["claimParked"]++;
        } catch { }
    }

    /// @notice A guardian's refunds flag, set or cleared.
    function refundsFlag(uint256 seat, bool set) external {
        calls++;
        _ratchet();
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
        _ratchet();
        uint256 n = packets.length;
        if (n == 0) return;
        i %= n; // no overflow in the walk below
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

    /// @notice Governance delivery and drain from a token hook inside a SEND (the transfer app busy, the router free):
    /// with decisions buffered so a drain has work, the delivery is refused with IBCAdmin's Busy (an error ack the
    /// router writes) and the drain records nothing; outside the send, the drain records the buffered decision.
    function busyGovernance(uint256 amount) external {
        calls++;
        _ratchet();
        if (ctl.routeClosed(_live())) return;
        // buffer: decisions L+2 .. L+10, then L+1 records itself and drains eight, leaving L+10 buffered
        uint64 last = admin.lastSeq();
        uint32 ep = admin.epoch();
        bytes memory params = P.unpause(1, _live());
        for (uint64 k = 2; k <= 10; k++) {
            IICS26RouterMsgs.Packet memory pk =
                _govPacket(abi.encodePacked(uint8(1), ep, last + k, S.KIND_UNPAUSE, params));
            try router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(pk, "", IICS02ClientMsgs.Height(0, 1))) { }
            catch {
                return;
            }
        }
        IICS26RouterMsgs.Packet memory first =
            _govPacket(abi.encodePacked(uint8(1), ep, last + 1, S.KIND_UNPAUSE, params));
        try router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(first, "", IICS02ClientMsgs.Height(0, 1))) { }
        catch {
            return;
        }
        if (admin.decision(ep, last + 10).state != S.BUFFERED) return;
        // the escrow is created by the route's first send: the hook fires on the transfer into it
        if (ics20.getEscrow(_live()) == address(0) && !_send(alice, address(hookToken), 1, true)) return;
        uint64 before = admin.lastSeq();
        IICS26RouterMsgs.Packet memory gov =
            _govPacket(abi.encodePacked(uint8(1), ep, last + 11, S.KIND_UNPAUSE, params));
        hookToken.setHook(ics20.getEscrow(_live()), address(busyProbe), abi.encodeCall(BusyProbe.probe, (gov)));
        amount = bound(amount, 1, 10);
        _limits(address(hookToken));
        string memory sentClient = _live();
        vm.recordLogs();
        vm.prank(alice);
        try ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg({
                denom: address(hookToken),
                amount: amount,
                receiver: "g1receiver",
                sourceClient: sentClient,
                destPort: ICS20Lib.DEFAULT_PORT_ID,
                timeoutTimestamp: uint64(_now() + 600),
                memo: ""
            })
        ) { }
        catch {
            hookToken.setHook(address(0), address(0), "");
            return;
        }
        hookToken.setHook(address(0), address(0), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!hookToken.hookOk()) return;
        // the specific refusal: the delivery from inside the send reverted whole, nothing written
        bool busy = busyProbe.deliveryReverted();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.SendPacket.selector) {
                packets.push(abi.decode(logs[i].data, (IICS26RouterMsgs.Packet)));
                ghost[packets.length - 1] = Ghost(true, false, false, false, alice, address(hookToken), amount);
                sentOver[packets.length - 1] = sentClient;
                redeemable[address(hookToken)] += amount;
                sentBy[alice][address(hookToken)] += amount;
            }
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.WriteAcknowledgement.selector) {
                busy = false; // an ack written for the delivery: consumed
            }
        }
        bool nothing = busyProbe.drained() == 0 && busyProbe.lastSeqSeen() == before
            && admin.decision(ep, last + 10).state == S.BUFFERED;
        if (busy && nothing && admin.drain() == 1 && admin.decision(ep, last + 10).state != S.BUFFERED) {
            ok["busyGovernance"]++;
        }
    }

    /// @notice A contract sender whose refund callback tries to re-enter the transfer app: the shared lock refuses it.
    function senderReentry(uint256 amount) external {
        calls++;
        _ratchet();
        amount = bound(amount, 1, 50);
        if (ctl.routeClosed(_live())) return;
        for (uint256 g = 0; g < 4; g++) {
            vm.prank(G[g]);
            try ctl.clearRefundsFlag(_live()) { } catch { }
        }
        try ctl.claim(_live(), tokens[2], 20) { } catch { }
        ERC20Mock(tokens[2]).mint(address(reentrant), amount);
        minted[address(reentrant)][tokens[2]] += amount;
        _limits(tokens[2]);
        vm.recordLogs();
        try reentrant.send(amount, _live()) { }
        catch {
            return;
        }
        if (!_record(false, address(reentrant), tokens[2], amount)) return;
        uint256 i = packets.length - 1;
        uint256 before = reentrant.callbacks();
        try router.ackPacket(
            IICS26RouterMsgs.MsgAckPacket(packets[i], ICS24Host.UNIVERSAL_ERROR_ACK, "", IICS02ClientMsgs.Height(0, 1))
        ) {
            _relayed(i);
        } catch {
            return;
        }
        bytes memory r = reentrant.reentryReason();
        if (
            reentrant.callbacks() == before + 1 && r.length >= 4
                && bytes4(r) == bytes4(keccak256("ReentrancyGuardReentrantCall()"))
        ) ok["senderReentryRefused"]++;
    }

    /// @notice A voucher (ugnot) received by bob: honest or forged; minted, never escrowed.
    function receiveVoucher(uint256 amount, bool forged) external {
        calls++;
        _ratchet();
        amount = bound(amount, 1, 1000);
        string memory dest = _live();
        IICS26RouterMsgs.Payload[] memory pl = new IICS26RouterMsgs.Payload[](1);
        pl[0] = IICS26RouterMsgs.Payload(
            ICS20Lib.DEFAULT_PORT_ID,
            ICS20Lib.DEFAULT_PORT_ID,
            ICS20Lib.ICS20_VERSION,
            ICS20Lib.ICS20_ENCODING,
            abi.encode(
                IICS20TransferMsgs.FungibleTokenPacketData({
                    denom: "ugnot", sender: "g1sender", receiver: Strings.toHexString(bob), amount: amount, memo: ""
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
            (address token, uint256 got) = ctl.receiveRecord(dest, seq);
            if (got != 0) {
                receives.push(Receive(dest, seq, got, token, forged));
                received[token] += got;
                ok["receiveVoucher"]++;
            }
        } catch { }
    }

    // -------------------------------------------------------------------------------------------- verifiers --

    /// @notice The live verifier freezes or expires (proofs through it are void), or kind 6 migrates it.
    function verifierEvent(uint256 what) external {
        calls++;
        _ratchet();
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
        return _executeAll(seqs); // the retirement noted as it executes
    }

    function replace(bool fromZero) external {
        calls++;
        _ratchet();
        if (clients.length >= 6) return;
        if (_replace(fromZero)) ok["replace"]++;
    }

    /// @notice The emergency recovery: the governance client goes bad, three guardians approve an attested client,
    /// and after the delay anyone executes it.
    function recover() external {
        calls++;
        _ratchet();
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
            _retire(next, 0);
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
            // a refund a forged success ack hid, proven owed: its backing is protected from now on; a delivered packet
            // proven so is released
            if (!ghost[i].delivered) provenOwed[i] = true;
            else provenDelivered[i] = true;
            _eligibleIfHeld(i);
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
        // every incident prepared first: no refund is paid before its suspect successes are reserved
        for (uint256 k = 0; k + 1 < clients.length; k++) {
            if (!_prepare(clients[k], 1000)) done = false;
        }
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
                if (!_prove(i, how % 3 + i)) {
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
                if (ctl.lossBooked(c, r.sequence, 2) || (heldBack == j + 1)) continue;
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
        if (done) ok["settle"] += n; // the settlements noted as it executes
    }

    function reconcile(uint256 how, bool all) external {
        calls++;
        _ratchet();
        if (_reconcile(how, all)) ok["reconcile"]++;
    }

    /// @notice Governance reconciles completely (every unsettled record of the retired clients and every forged
    /// receive on them, as §7.12 asks; the controls enforce only the suspected interval), then kind 13.
    function _reopen() internal returns (bool) {
        _reconcile(0, true);
        return _reopenOnly();
    }

    /// @notice Kind 13 through IBCAdmin, then its continuation until the route opens (or the reopening aborts).
    function _reopenOnly() internal returns (bool) {
        if (!_executeAll(_one(_decide(S.KIND_REOPEN, P.reopen(_live()))))) return false;
        ok["reopen"]++;
        _snapshotNew();
        _checkpoint();
        for (uint256 i = 0; i < 32 && ctl.routeReopening(_live()); i++) {
            if (_continue(true)) ok["continueReopen"]++;
        }
        return !ctl.routeClosed(_live());
    }

    function reopen() external {
        calls++;
        _ratchet();
        _reopen();
    }

    function continueReopen() external {
        calls++;
        _ratchet();
        if (_continue(true)) ok["continueReopen"]++;
    }

    /// @notice One `continueReopen` batch, with the exact incident transitions it may make: the reopening incidents
    /// stay reopening, all become resolved when the route opens, or all open again when it aborts; no other incident
    /// changes. `check`: the invariants after it (not while a test-only fault stands).
    function _continue(bool check) internal returns (bool done) {
        string memory live = _live();
        if (!ctl.routeReopening(live)) return false;
        (T.Incident[] memory before, uint64 r0,) = ctl.incidents(live);
        // a batch of 1 to 8 deficits (kind 13 takes 16; LOSS_TOKENS leaves several continuations, some not the last)
        uint256 size = 1 + uint256(keccak256(abi.encode(contSeed++))) % 8;
        try ctl.continueReopen(live, size) {
            done = true;
        } catch {
            return false;
        }
        (T.Incident[] memory after_, uint64 r1,) = ctl.incidents(live);
        bool opened = !ctl.routeClosed(live);
        bool aborted = !opened && !ctl.routeReopening(live);
        assertEq(after_.length, before.length, "no incident added by a batch");
        for (uint256 k = 0; k < before.length; k++) {
            uint8 want = before[k].status;
            if (want == 2) want = opened ? 3 : (aborted ? 1 : 2);
            assertEq(after_[k].status, want, "an incident's transition");
        }
        assertEq(r1, opened ? uint64(after_.length) : r0, "resolvedUpTo");
        if (aborted) ok["abortObserved"]++;
        if (!opened && !aborted) ok["continueNonTerminal"]++;
        if (check) _checkpoint();
    }

    /// @notice Forged refunds paid on LOSS_TOKENS tokens, a replacement and its reconciliation: a kind 13 whose
    /// deficits need more than one batch, left reopening.
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
            if (clients.length >= 64) return false;
            for (uint256 t = 1; t <= LOSS_TOKENS; t++) {
                if (!_send(alice, tokens[t], 1, true)) return false;
                uint256 i = packets.length - 1;
                try router.ackPacket(
                    IICS26RouterMsgs.MsgAckPacket(
                        packets[i], ICS24Host.UNIVERSAL_ERROR_ACK, "", IICS02ClientMsgs.Height(0, 1)
                    )
                ) {
                    _relayed(i);
                    ghost[i].forgedRefund = true;
                } catch { }
            }
            if (!_replace(true)) return false;
        }
        if (!_reconcile(0, true)) return false;
        if (!_executeAll(_one(_decide(S.KIND_REOPEN, P.reopen(_live()))))) return false;
        ok["reopen"]++;
        _snapshotNew();
        _checkpoint();
        return ctl.routeReopening(_live());
    }

    /// @notice A replacement while a reopening is under way: it aborts the reopening.
    function replaceDuringReopening() external {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_startLongReopening()) return;
        if (_replace(true) && !ctl.routeReopening(_live())) ok["replaceDuringReopening"]++;
    }

    /// @notice A loss found after the route reopened: kind 12 on a remaining record of a resolved incident (or a
    /// forged receive) closes the route again; a new kind 13 accepts it.
    function lateLoss(uint256 how) external {
        calls++;
        _ratchet();
        if (ctl.routeClosed(_live())) return;
        if (_reconcile(how, true) && ctl.routeClosed(_live())) {
            ok["lateLoss"]++;
            _reopen();
        }
    }

    function warp(uint256 dt) external {
        calls++;
        _ratchet();
        _skip(bound(dt, 1, 2 days));
    }

    /// @notice The route open again: a reopening under way continued, a closed route reconciled and reopened.
    function _ensureOpen() internal returns (bool) {
        // an emergency recovery left open (its execution failed) blocks the route: the guardians cancel it
        (, uint64 openedAt,,) = admin.recovery();
        for (uint256 g = 0; openedAt != 0 && g < 4; g++) {
            vm.prank(G[g]);
            try admin.cancelRecovery() { } catch { }
            (, openedAt,,) = admin.recovery();
        }
        for (uint256 i = 0; i < 32 && ctl.routeReopening(_live()); i++) {
            if (_continue(true)) ok["continueReopen"]++;
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
        _ratchet();
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
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        if (!_send(alice, tokens[1], 10, true)) return;
        this.relay(packets.length - 1, true, false); // a forged error ack: refunded at once
        _skip(1 days);
        if (!_replace(false)) return; // its interval starts after the forged refund
        _reconcile(0, false); // only what kind 13 waits for: the forged refund is left
        _markLeftOut(); // and so is every forged payout not yet booked: governance finds them late, by design
        if (!_reopenOnly()) return;
        // found after the reopening (in this same step): its loss closes the route again
        if (_reconcile(1, true) && ctl.routeClosed(_live())) {
            ok["lateLoss"]++;
            _reopen();
        }
    }

    /// @notice Marks every forged outcome not reconciled yet (a forged refund's record, a refund a forged success ack
    /// hides, a forged receive) as left out of the reconciliation: the scenario's governance finds them only after the
    /// reopening.
    function _markLeftOut() internal {
        for (uint256 i = 0; i < packets.length; i++) {
            bool unbooked = ghost[i].forgedRefund && !ctl.lossBooked(packets[i].sourceClient, packets[i].sequence, 1);
            bool hidden =
                ghost[i].forgedSuccess && ctl.sendRecord(packets[i].sourceClient, packets[i].sequence).settlement == 0;
            if (unbooked || hidden) {
                leftOutSend[i + 1] = true;
            }
        }
        for (uint256 j = 0; j < receives.length; j++) {
            if (receives[j].forged && !ctl.lossBooked(receives[j].client, receives[j].sequence, 2)) {
                leftOut[j + 1] = true;
            }
        }
    }

    /// @notice Proof and settlement apart, against a verifier that changed between them, and the settlements the
    /// controls must refuse: a mismatched action, a settlement against a frozen verifier, a replay; and an emergency
    /// recovery approved then cancelled by the guardians.
    function adversarialRound(uint256 seed) public {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        if (!_send(alice, tokens[0], 10, false)) return;
        uint256 i = packets.length - 1;
        IICS26RouterMsgs.Packet memory pkt = packets[i];
        if (!_replace(seed & 1 == 1)) return;
        if (!_prove(i, seed >> 1)) return;
        ok["proveOnly"]++;
        string memory c = pkt.sourceClient;
        // a mismatched action: "delivered" for a packet proven not delivered
        uint64 s1 = _decide(S.KIND_SETTLE, P.settle1(c, pkt.sequence, 3, 0));
        _executeAll(_one(s1));
        if (
            s1 != 0 && admin.decision(admin.epoch(), s1).state == S.SPENT
                && ctl.sendRecord(c, pkt.sequence).settlement == 0
        ) {
            ok["mismatchRefused"]++;
        }
        // the verifier freezes after the proof: the settlement against it is spent
        _liveClient().setStatus(true, false);
        uint64 s2 = _decide(S.KIND_SETTLE, P.settle1(c, pkt.sequence, 1, 10));
        _executeAll(_one(s2));
        if (
            s2 != 0 && admin.decision(admin.epoch(), s2).state == S.SPENT
                && ctl.sendRecord(c, pkt.sequence).settlement == 0
        ) {
            ok["settleStaleRefused"]++;
        }
        _liveClient().setStatus(false, false);
        // proven again through the healthy verifier, settled once, then a replay spent
        _prove(i, seed >> 1);
        uint64 s3 = _decide(S.KIND_SETTLE, P.settle1(c, pkt.sequence, 1, 10));
        if (_executeAll(_one(s3))) {
            ok["settle"]++;
            uint256 paid = ctl.sendRecord(c, pkt.sequence).refunded;
            uint64 s4 = _decide(S.KIND_SETTLE, P.settle1(c, pkt.sequence, 1, 10));
            _executeAll(_one(s4));
            if (
                s4 != 0 && admin.decision(admin.epoch(), s4).state == S.SPENT
                    && ctl.sendRecord(c, pkt.sequence).refunded == paid
            ) {
                ok["replayRefused"]++;
            }
        }
        // an emergency recovery approved, then cancelled by three guardians: nothing changes
        string memory gov = admin.govClient();
        _liveClient().setStatus(true, false);
        IIBCAdmin.RecoveryProposal memory p = IIBCAdmin.RecoveryProposal({
            newClientId: string.concat("gnoland-", vm.toString(500 + clients.length)),
            counterpartyClientId: "ethereum-cancel",
            merklePrefix: _prefix(),
            lightClient: address(new MockLightClient()),
            codeHash: address(_liveClient()).codehash,
            suspectFrom: 0
        });
        bool opened = true;
        for (uint256 g = 0; g < 3; g++) {
            vm.prank(G[g]);
            try admin.approveRecovery(p) { }
            catch {
                opened = false;
            }
        }
        (, uint64 openedAt,,) = admin.recovery();
        if (opened && openedAt != 0) {
            for (uint256 g = 0; g < 3; g++) {
                vm.prank(G[g]);
                try admin.cancelRecovery() { } catch { }
            }
            (, openedAt,,) = admin.recovery();
            if (openedAt == 0 && keccak256(bytes(admin.govClient())) == keccak256(bytes(gov))) {
                ok["recoveryCancelled"]++;
            }
        }
        _liveClient().setStatus(false, false);
        _reopen();
    }

    // ------------------------------------------------------------------------------ split governance steps --

    /// @notice Records a replacement (kind 6 adding a client, kind 10) without executing it.
    function startReplacement(bool fromZero) external {
        calls++;
        _ratchet();
        if (clients.length >= 64) return;
        string memory next = string.concat("gnoland-s", vm.toString(++nonce));
        MockLightClient fresh = new MockLightClient();
        uint64 a = _decide(
            S.KIND_CLIENT,
            P.client(
                1,
                next,
                string.concat("ethereum-s", vm.toString(nonce)),
                _prefix(),
                address(fresh),
                address(fresh).codehash
            )
        );
        uint64 b = _decide(S.KIND_ROUTE, P.route(_live(), next, fromZero ? 0 : uint64(vm.getBlockNumber())));
        if (a == 0 || b == 0) return;
        pending.push(a);
        pending.push(b);

        ok["startReplacement"]++;
    }

    /// @notice Records a kind 12 for a retired record (the action its truth calls for), without executing it.
    function decideSettle(uint256 i) external {
        calls++;
        _ratchet();
        if (packets.length == 0) return;
        i = i % packets.length;
        if (!ctl.isRetired(packets[i].sourceClient)) return;
        T.SettleItem memory it = _action(i);
        uint64 s = _decide(S.KIND_SETTLE, P.settle1(packets[i].sourceClient, it.sequence, it.action, it.amount));
        if (s == 0) return;
        pending.push(s);
        ok["decideSettle"]++;
    }

    /// @notice Records a kind 13 without executing it.
    function startReopen() external {
        calls++;
        _ratchet();
        uint64 s = _decide(S.KIND_REOPEN, P.reopen(_live()));
        if (s == 0) return;
        pending.push(s);
        ok["startReopen"]++;
    }

    /// @notice Proves a retired record's outcome through the live client, whatever its health.
    function proveOne(uint256 i, uint256 how) external {
        calls++;
        _ratchet();
        if (packets.length == 0) return;
        i = i % packets.length;
        if (!ctl.isRetired(packets[i].sourceClient)) return;
        T.SendRecord memory rec = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence);
        if (rec.settlement != 0) return;
        if (_prove(i, how % 3)) ok["proveOne"]++;
    }

    /// @notice Matures and executes the recorded decisions, in order (a decision of another epoch is gone).
    function executePending() external {
        calls++;
        _ratchet();
        if (pending.length == 0) return;
        _skip(7 days + 1);
        uint32 ep = admin.epoch();
        uint256 n;
        for (uint256 k = 0; k < pending.length; k++) {
            uint64 s = pending[k];
            if (admin.decision(ep, s).state != S.PENDING) continue;
            // the documented precondition of kind 13 (§7.12): governance has reconciled completely before it
            // executes; the controls enforce only the suspected interval and the open records (their own refusals
            // are tested separately)
            if (admin.decision(ep, s).kind == S.KIND_REOPEN) _reconcile(0, true);
            IIBCAdmin.Decision memory dec = admin.decision(ep, s);
            try admin.execute(s) { } catch { }
            if (_noteExecuted(ep, s, dec)) n++;
            _checkpoint();
        }
        delete pending;
        if (n != 0) ok["executePending"]++;
    }

    // ---------------------------------------------------------------------------------- more adversaries --

    /// @notice bob returns vouchers to gno.land (a burn); its outcome is relayed honestly or forged later.
    function sendVoucher(uint256 amount, bool delivered) external {
        calls++;
        _ratchet();
        uint256 bal = ugnot.balanceOf(bob);
        if (bal == 0) return;
        if (_send(bob, address(ugnot), (amount % bal) + 1, delivered)) ok["sendVoucher"]++;
    }

    /// @notice A contract sender refuses its refund notification: the refund stands, the notification is kept.
    function adapterRefuses(uint256 amount) external {
        calls++;
        _ratchet();
        if (ctl.routeClosed(_live())) return;
        amount = amount % 50 + 1;
        ERC20Mock(tokens[0]).mint(address(adapter), amount);
        minted[address(adapter)][tokens[0]] += amount;
        _limits(tokens[0]);
        try ctl.claim(_live(), tokens[0], 20) { } catch { }
        vm.recordLogs();
        try adapter.send(amount, _live()) { }
        catch {
            return;
        }
        if (!_record(false, address(adapter), tokens[0], amount)) return;
        uint256 i = packets.length - 1;
        adapter.setRefuse(true);
        vm.recordLogs();
        try router.ackPacket(
            IICS26RouterMsgs.MsgAckPacket(packets[i], ICS24Host.UNIVERSAL_ERROR_ACK, "", IICS02ClientMsgs.Height(0, 1))
        ) {
            _relayed(i);
        } catch {
            adapter.setRefuse(false);
            return;
        }
        adapter.setRefuse(false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k = 0; k < logs.length; k++) {
            if (
                logs[k].topics[0] == T.GnoSenderNotified.selector
                    && logs[k].topics[1] == bytes32(uint256(packets[i].sequence))
            ) {
                (, bool delivered) = abi.decode(logs[k].data, (string, bool));
                T.SendRecord memory rec = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence);
                if (!delivered && rec.refunded == amount) ok["adapterRefused"]++;
            }
        }
    }

    /// @notice Settlement against an expired verifier, and against a proof a verifier migration (a new
    /// generation) made stale: both spent, the record unchanged.
    function staleSettlements(uint256 seed) public {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        if (!_send(alice, tokens[0], 10, false)) return;
        uint256 i = packets.length - 1;
        IICS26RouterMsgs.Packet memory pkt = packets[i];
        if (!_replace(true)) return;
        string memory c = pkt.sourceClient;
        if (!_prove(i, seed)) return;
        _liveClient().setStatus(false, true); // expired after the proof
        uint64 s1 = _decide(S.KIND_SETTLE, P.settle1(c, pkt.sequence, 1, 10));
        _executeAll(_one(s1));
        if (
            s1 != 0 && admin.decision(admin.epoch(), s1).state == S.SPENT
                && ctl.sendRecord(c, pkt.sequence).settlement == 0
        ) {
            ok["settleExpiredRefused"]++;
        }
        _liveClient().setStatus(false, false);
        // a kind 6 migration of the live client to another verifier: a new generation, the proof stale
        MockLightClient fresh = new MockLightClient();
        string memory live = _live();
        uint64 m = _decide(
            S.KIND_CLIENT,
            P.client(2, live, router.getCounterparty(live).clientId, _prefix(), address(fresh), address(fresh).codehash)
        );
        if (!_executeAll(_one(m))) return;
        uint64 s2 = _decide(S.KIND_SETTLE, P.settle1(c, pkt.sequence, 1, 10));
        _executeAll(_one(s2));
        if (
            s2 != 0 && admin.decision(admin.epoch(), s2).state == S.SPENT
                && ctl.sendRecord(c, pkt.sequence).settlement == 0
        ) {
            ok["settleStaleGenRefused"]++;
        }
        _reopen();
    }

    /// @notice A loss booked between deficit batches is refused (the reopening seals the losses, invariant 7): a
    /// forged receive governance left out of its reconciliation, booked by kind 12 action 5 while the deficit
    /// batches run, is spent with every loss unchanged; booked after the route opened, it is a late loss.
    function lossDuringReopening(uint256 amount) external {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        // a delivered send first: the escrow then holds what the forged receive releases
        if (!_send(alice, tokens[0], 60, true)) return;
        this.relay(packets.length - 1, false, false); // its success ack releases the reservation
        uint256 before = receives.length;
        this.receive_(0, amount % 50 + 1, true);
        if (receives.length == before) return;
        Receive memory r = receives[before];
        heldBack = before + 1;
        leftOut[before + 1] = true;
        bool started = _startLongReopening();
        heldBack = 0;
        if (!started || !ctl.isRetired(r.client)) return;
        uint256 l = ctl.losses(_live(), r.token);
        uint64 s = _decide(S.KIND_SETTLE, P.settle1(r.client, r.sequence, 5, r.amount));
        _executeAll(_one(s));
        if (
            s != 0 && admin.decision(admin.epoch(), s).state == S.SPENT && ctl.losses(_live(), r.token) == l
                && !ctl.lossBooked(r.client, r.sequence, 2) && ctl.routeReopening(_live())
        ) ok["lossDuringReopeningRefused"]++;
        // the reopening finishes; the left-out receive is then booked as a late loss and accepted again
        _ensureOpen();
        if (_reconcile(0, true) && ctl.routeClosed(_live())) _reopen();
    }

    /// @notice Authority changes between an emergency recovery's approval and its execution are suspended.
    function recoverWithAuthorityAttempts() external {
        calls++;
        _ratchet();
        if (clients.length >= 64) return;
        _ensureOpen();
        string memory next = string.concat("gnoland-r", vm.toString(++nonce));
        MockLightClient fresh = new MockLightClient();
        // decisions recorded before the recovery opens
        MockLightClient other = new MockLightClient();
        uint64 add = _decide(
            S.KIND_CLIENT,
            P.client(
                1,
                string.concat(next, "x"),
                string.concat("ethereum-x", vm.toString(nonce)),
                _prefix(),
                address(other),
                address(other).codehash
            )
        );
        _liveClient().setStatus(true, false);
        IIBCAdmin.RecoveryProposal memory p = IIBCAdmin.RecoveryProposal({
            newClientId: next,
            counterpartyClientId: string.concat("ethereum-r", vm.toString(nonce)),
            merklePrefix: _prefix(),
            lightClient: address(fresh),
            codeHash: address(fresh).codehash,
            suspectFrom: 0
        });
        for (uint256 g = 0; g < 3; g++) {
            vm.prank(G[g]);
            try admin.approveRecovery(p) { }
            catch {
                _liveClient().setStatus(false, false);
                return;
            }
        }
        _skip(7 days + 1);
        bool suspended;
        if (add != 0) {
            try admin.execute(add) { }
            catch (bytes memory r) {
                suspended = r.length >= 4 && bytes4(r) == IIBCAdmin.Suspended.selector;
            }
        }
        _skip(30 days);
        try admin.executeRecovery() {
            _retire(next, 0);
            ok["recover"]++;
            if (suspended) ok["authoritySuspended"]++;
        } catch { }
    }

    /// @notice The defensive re-check at the last deficit batch, driven by fault injection (test only): the
    /// pending-incident count raised between batches makes the last batch abort the reopening instead of opening
    /// the route; restored, the route reopens.
    function faultInjectedAbort() external {
        calls++;
        _ratchet();
        if (!_startLongReopening()) return;
        (bytes32 slot, uint256 shift) = _pendingSlot();
        if (slot == bytes32(0)) return;
        (, uint64 resolved0,) = ctl.incidents(_live());
        vm.store(address(ics20), slot, bytes32(uint256(vm.load(address(ics20), slot)) + (uint256(1) << shift)));
        // the batches check the exact transitions themselves (`_continue`); the invariants wait for the fault's removal
        for (uint256 i = 0; i < 32 && ctl.routeReopening(_live()); i++) {
            _continue(false);
        }
        bool aborted = !ctl.routeReopening(_live()) && ctl.routeClosed(_live());
        // the fault removed: only the injected bit, never the transition's own writes in the same word
        vm.store(address(ics20), slot, bytes32(uint256(vm.load(address(ics20), slot)) - (uint256(1) << shift)));
        (T.Incident[] memory inc, uint64 resolved1,) = ctl.incidents(_live());
        assertEq(resolved1, resolved0, "an abort resolves nothing");
        for (uint256 k = resolved1; aborted && k < inc.length; k++) {
            assertEq(inc[k].status, 1, "aborted: every unresolved incident open again");
        }
        _checkpoint();
        if (aborted) ok["abortInjected"]++;
        _reopen();
    }

    /// @notice The storage word holding the route's pending-incident count, found by recording the view's reads and
    /// probing them (test-only fault injection).
    function _pendingSlot() internal returns (bytes32, uint256) {
        (,, uint64 before) = ctl.incidents(_live());
        vm.record();
        ctl.incidents(_live());
        (bytes32[] memory reads,) = vm.accesses(address(ics20));
        for (uint256 k = 0; k < reads.length; k++) {
            bytes32 orig = vm.load(address(ics20), reads[k]);
            for (uint256 shift = 0; shift < 256; shift += 64) {
                vm.store(address(ics20), reads[k], bytes32(uint256(orig) ^ (uint256(1) << shift)));
                // a staticcall: a probed word may be one the call cannot survive (the implementation slot)
                // and bounded: a flipped array length would otherwise burn the run's gas
                (bool okCall, bytes memory ret) =
                    address(ctl).staticcall{ gas: 1_000_000 }(abi.encodeCall(IGnoICS20Controls.incidents, (_live())));
                vm.store(address(ics20), reads[k], orig);
                if (!okCall || ret.length < 96) break;
                (,, uint64 now_) = abi.decode(ret, (T.Incident[], uint64, uint64));
                if (now_ == (before ^ 1)) return (reads[k], shift);
            }
        }
        return (bytes32(0), 0);
    }

    // ------------------------------------------------------------------------------------- round 11 actions --

    /// @notice A delivered packet of a contract sender whose success ack A (other bytes than the one gno.land wrote)
    /// a compromised verifier accepted while the sender refused the notification; reconciliation proves the
    /// authentic ack B and settles action 3: the sender is told of the success once, with B.
    function forgedSuccessAck(uint256 amount) external {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        amount = amount % 50 + 1;
        ERC20Mock(tokens[0]).mint(address(adapter), amount);
        minted[address(adapter)][tokens[0]] += amount;
        _limits(tokens[0]);
        try ctl.claim(_live(), tokens[0], 20) { } catch { }
        vm.recordLogs();
        try adapter.send(amount, _live()) { }
        catch {
            return;
        }
        if (!_record(true, address(adapter), tokens[0], amount)) return;
        uint256 i = packets.length - 1;
        adapter.setRefuse(true);
        try router.ackPacket(
            IICS26RouterMsgs.MsgAckPacket(
                packets[i], bytes("{\"result\":\"Zm9yZ2Vk\"}"), "", IICS02ClientMsgs.Height(0, 1)
            )
        ) {
            _relayed(i);
        } catch { }
        adapter.setRefuse(false);
        if (!ghost[i].relayed || !_replace(true) || !_prove(i, 0)) return;
        T.SettleItem[] memory items = new T.SettleItem[](1);
        items[0] = _action(i);
        if (items[0].action != 3 || !_settleBatch(packets[i].sourceClient, items, 1)) return;
        uint256 before = adapter.successes();
        bytes memory proven = bytes("{\"result\":\"AQ==\"}");
        try ctl.notifySettled(packets[i], proven, 0) returns (bool d) {
            if (d && adapter.successes() == before + 1 && adapter.lastAck() == keccak256(proven)) {
                ok["provenAckReplaced"]++;
            }
        } catch { }
        _checkpoint();
        _reopen();
    }

    /// @notice Before a recovery opens, a guardian withdraws its approval: the third approval no longer opens it;
    /// approved again, it opens, and three guardians cancel it.
    function withdrawApproval() external {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        (, uint64 openedAt,,) = admin.recovery();
        if (openedAt != 0) return;
        string memory next = string.concat("gnoland-w", vm.toString(++nonce));
        MockLightClient fresh = new MockLightClient();
        IIBCAdmin.RecoveryProposal memory p = IIBCAdmin.RecoveryProposal({
            newClientId: next,
            counterpartyClientId: string.concat("ethereum-w", vm.toString(nonce)),
            merklePrefix: _prefix(),
            lightClient: address(fresh),
            codeHash: address(fresh).codehash,
            suspectFrom: 0
        });
        _liveClient().setStatus(true, false); // eligible
        bool ok_ = _approve(0, p) && _approve(1, p);
        if (ok_) {
            vm.prank(G[0]);
            admin.cancelRecovery(); // before it opens: a withdrawal
            ok_ = _approve(2, p);
        }
        (, openedAt,,) = admin.recovery();
        bool held = ok_ && openedAt == 0;
        _checkpoint();
        if (held && _approve(0, p)) {
            (, openedAt,,) = admin.recovery();
            if (openedAt != 0) ok["approvalWithdrawn"]++;
        }
        _checkpoint();
        for (uint256 g = 0; g < 3 && openedAt != 0; g++) {
            vm.prank(G[g]);
            admin.cancelRecovery();
            (, openedAt,,) = admin.recovery();
        }
        _liveClient().setStatus(false, false);
    }

    function _approve(uint256 g, IIBCAdmin.RecoveryProposal memory p) internal returns (bool) {
        vm.prank(G[g]);
        try admin.approveRecovery(p) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice A retired client that is not frozen (kind 10 freezes it; here the freeze is defeated, test only, by
    /// running the mock client's code at the frozen client's address for one call) delivers an honest ack or error ack
    /// of one of its outstanding records while its incident is unresolved: the transfer app's ack hook counts it as
    /// suspect work of that incident (a reopening under way then aborts at its last batch).
    function retiredAck(uint256 i) external {
        calls++;
        _ratchet();
        if (packets.length == 0) return;
        i = i % packets.length;
        IICS26RouterMsgs.Packet memory pkt = packets[i];
        if (ghost[i].relayed || !ctl.isRetired(pkt.sourceClient) || !ctl.routeClosed(_live())) return;
        T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        if (rec.settlement != 0 || rec.outcome != T.Outcome.Pending) return;
        address frozen = address(router.getClient(pkt.sourceClient));
        bytes memory code = frozen.code;
        vm.etch(frozen, address(new MockLightClient()).code);
        bytes memory ack = ghost[i].delivered ? bytes("{\"result\":\"AQ==\"}") : ICS24Host.UNIVERSAL_ERROR_ACK;
        bool done;
        try router.ackPacket(IICS26RouterMsgs.MsgAckPacket(pkt, ack, "", IICS02ClientMsgs.Height(0, 1))) {
            done = true;
        } catch { }
        vm.etch(frozen, code); // frozen again
        if (!done) return;
        _relayed(i);
        (,,, uint64 suspect,) = ctl.clientRecon(pkt.sourceClient);
        if (suspect != 0) ok["retiredAck"]++;
        _checkpoint();
    }

    // ------------------------------------------------------------------------------------- round 12 actions --

    /// @notice A kind 13 executed while the ghost says a retired client of an unresolved incident still has work
    /// (an open or a suspect record): it must be spent, and the route stay closed. No reconciliation first.
    function prematureReopen() public {
        calls++;
        _ratchet();
        if (!ctl.routeClosed(_live()) || ctl.routeReopening(_live())) return;
        bool work;
        for (uint256 k = 0; k + 1 < clients.length && !work; k++) {
            (, uint32 incident,,,) = ctl.clientRecon(clients[k]);
            (, uint64 resolvedUpTo,) = ctl.incidents(_live());
            if (incident == 0 || incident - 1 < resolvedUpTo) continue;
            (uint64 o, uint64 sus) = expectedWork(clients[k]);
            work = o != 0 || sus != 0;
        }
        if (!work) return;
        uint64 s = _decide(S.KIND_REOPEN, P.reopen(_live()));
        if (s == 0) return;
        _executeAll(_one(s));
        IIBCAdmin.Decision memory dec = admin.decision(admin.epoch(), s);
        assertTrue(dec.state != S.EXECUTED, "a kind 13 executed while work remained");
        assertTrue(ctl.routeClosed(_live()) && !ctl.routeReopening(_live()), "the route stays closed");
        ok["prematureReopenRefused"]++;
    }

    /// @notice A settled record's late ack or timeout (the retired client's freeze defeated for this one call, test
    /// only, as in `retiredAck`): ignored, nothing paid, the record unchanged.
    function lateOnSettled(uint256 i, bool useTimeout) public {
        calls++;
        _ratchet();
        if (packets.length == 0) return;
        i = i % packets.length;
        IICS26RouterMsgs.Packet memory pkt = packets[i];
        if (ghost[i].relayed || settledCount[keccak256(abi.encode(pkt.sourceClient, pkt.sequence))] == 0) return;
        T.SendRecord memory before = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        address token = ghost[i].token;
        uint256 senderBal = IERC20(token).balanceOf(ghost[i].sender);
        address frozen = address(router.getClient(pkt.sourceClient));
        bytes memory code = frozen.code;
        vm.etch(frozen, address(new MockLightClient()).code);
        bool done;
        if (useTimeout) {
            MockLightClient(frozen).setTimestamp(pkt.timeoutTimestamp);
            try router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(pkt, "", IICS02ClientMsgs.Height(0, 1))) {
                done = true;
            } catch { }
        } else {
            bytes memory ack = ghost[i].delivered ? bytes("{\"result\":\"AQ==\"}") : ICS24Host.UNIVERSAL_ERROR_ACK;
            try router.ackPacket(IICS26RouterMsgs.MsgAckPacket(pkt, ack, "", IICS02ClientMsgs.Height(0, 1))) {
                done = true;
            } catch { }
        }
        vm.etch(frozen, code); // frozen again
        if (!done) return;
        _relayed(i); // the commitment is consumed, nothing else
        T.SendRecord memory after_ = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        assertEq(after_.refunded, before.refunded, "nothing refunded");
        assertEq(uint8(after_.payment), uint8(before.payment), "payment unchanged");
        assertEq(uint8(after_.outcome), uint8(before.outcome), "outcome unchanged");
        assertEq(after_.settlement, before.settlement, "settlement unchanged");
        assertEq(after_.processedBlock, before.processedBlock, "not processed");
        assertEq(IERC20(token).balanceOf(ghost[i].sender), senderBal, "nothing paid");
        ok["lateOnSettledIgnored"]++;
        _checkpoint();
    }

    // ------------------------------------------------------------------------------------- round 13 actions --

    /// @notice A refund partly backed: a forged success ack hides an undelivered send's refund, a forged receive
    /// takes most of the escrow it would have used, and reconciliation owes the refund again with only part of it
    /// left (the payment fails: it stays owed). Receives must not take the rest: the shortfall stays what
    /// reconciliation recognized.
    function partialBacking() external {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        address p = partialToken;
        _limits(p);
        if (!_send(alice, p, 100, false)) return;
        uint256 i = packets.length - 1;
        this.relay(i, true, false); // a forged success ack: the reservation released
        if (!ghost[i].forgedSuccess) return;
        address escrow = ics20.getEscrow(_live());
        uint256 bal = IERC20(p).balanceOf(escrow);
        uint256 reserved = ctl.reserved(_live(), p);
        if (bal < reserved + 50) return;
        // a forged receive takes all but 50 above the reservation (allowed: nothing reserves it)
        if (bal - reserved - 50 != 0 && !_receiveToken(p, bal - reserved - 50, true)) return;
        if (!_replace(true)) return;
        _reconcile(0, true); // the refund owed again: 100 against 50
        T.SendRecord memory rec = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence);
        if (rec.settlement != 1 || rec.refunded != 0 || uncovered(p) == 0) {
            _ensureOpen();
            return;
        }
        // the route reopened (the forged receive booked and accepted), the refund still owed and partly backed: a
        // receive on the new live client (forged, or honest) must not take the 50 left
        if (!_reopen() || uncovered(p) == 0) {
            _ensureOpen();
            return;
        }
        uint256 before = IERC20(p).balanceOf(escrow);
        bool refused = !_receiveToken(p, 50, true) && !_receiveToken(p, 1, false);
        if (refused && IERC20(p).balanceOf(escrow) == before) ok["partialBackingHeld"]++;
        // a new outstanding send escrows 100 more; the older refund, retried, must not take the new send's backing
        if (_send(alice, p, 100, true)) {
            uint256 reservedBefore = ctl.reserved(_live(), p);
            uint256 refunded = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence).refunded;
            try ctl.claim(_live(), p, 20) { } catch { }
            try ctl.claimParked(packets[i].sourceClient, packets[i].sequence, 300_000) { } catch { }
            uint256 paid = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence).refunded - refunded;
            // whatever was paid, every other record's reservation is still backed in full
            uint256 others = reservedBefore - (100 - refunded);
            assertGe(IERC20(p).balanceOf(escrow), others, "a refund took another record's backing");
            if (paid == 0) ok["olderRefundHeld"]++;
        }
        partialDone = true;
        _ensureOpen();
    }

    /// @notice The route-wide seal: a loss on a record of an incident already resolved (A) is refused while another
    /// incident (B) reopens. The forged receive on A's client is left out of A's reconciliation (the deliberate
    /// late-loss exception), so A resolves with it unbooked; booked during B's reopening, the incident-status check
    /// passes (A is resolved) and only the route-wide seal refuses it.
    function lossResolvedIncidentDuringReopening() external {
        calls++;
        _ratchet();
        if (clients.length >= 62 || !_ensureOpen()) return;
        if (!_send(alice, tokens[0], 60, true)) return;
        this.relay(packets.length - 1, false, false);
        uint256 before = receives.length;
        this.receive_(0, 7, true);
        if (receives.length == before) return;
        Receive memory r = receives[before];
        heldBack = before + 1;
        leftOut[before + 1] = true;
        // incident A: the receive's client retired, reconciled without it, reopened
        bool aDone = _replace(true) && _reopen() && !ctl.routeClosed(_live());
        // incident B, reopening over several batches
        bool bReopening = aDone && _startLongReopening();
        heldBack = 0;
        if (!bReopening || ctl.lossBooked(r.client, r.sequence, 2)) {
            _ensureOpen();
            return;
        }
        uint256 l = ctl.losses(_live(), r.token);
        uint64 s = _decide(S.KIND_SETTLE, P.settle1(r.client, r.sequence, 5, r.amount));
        _executeAll(_one(s));
        if (
            s != 0 && admin.decision(admin.epoch(), s).state == S.SPENT && ctl.losses(_live(), r.token) == l
                && !ctl.lossBooked(r.client, r.sequence, 2) && ctl.routeReopening(_live())
        ) ok["lossResolvedIncidentSealed"]++;
        // B finishes; the left-out receive is then a late loss, accepted by a new kind 13
        _ensureOpen();
        if (_reconcile(0, true) && ctl.routeClosed(_live())) _reopen();
    }

    // ------------------------------------------------------------------------------------- round 15 actions --

    /// @notice A guardian replaced (kind 3) during a dip of the live route's flags, on IBCAdmin's key list (the
    /// transfer app's copy follows): G0 and G1 flag, G1 clears (a dip), G0's key is replaced. No guardian flag
    /// stands any more, so the hold ends at once. G0's key is then put back (another kind 3).
    function replaceDuringDip(bool refunds) public {
        calls++;
        _ratchet();
        if (!_ensureOpen()) return;
        (, uint64 openedAt,,) = admin.recovery();
        if (openedAt != 0) return; // kind 3 waits while a recovery is open
        string memory live = _live();
        for (uint256 g = 0; g < 2; g++) {
            vm.prank(G[g]);
            if (refunds) {
                try ctl.setRefundsFlag(live) { }
                catch {
                    return;
                }
            } else {
                try ctl.setRouteFlag(live) { }
                catch {
                    return;
                }
            }
        }
        address fresh = makeAddr(string.concat("replacement-", vm.toString(++nonce)));
        uint64 out = _decide(S.KIND_SEATS, P.seat1(0, fresh));
        // the dip starts a little before the replacement matures (well within the 24-hour grace)
        _skip(7 days - 1 hours);
        vm.prank(G[1]);
        if (refunds) ctl.clearRefundsFlag(live);
        else ctl.clearRouteFlag(live);
        bool dip = (refunds ? ctl.refundsHold(live) : ctl.routeHold(live)).blockNumber != 0;
        _skip(1 hours + 1);
        try admin.execute(out) { } catch { }
        bool ended = admin.decision(admin.epoch(), out).state == S.EXECUTED
            && (refunds ? ctl.refundsHold(live) : ctl.routeHold(live)).blockNumber == 0;
        _checkpoint();
        if (dip && ended) ok[refunds ? "replaceInDipRefunds" : "replaceInDipRoute"]++;
        // G0's key back (recorded now: a kind 3 naming a seat's current key is spent at recording), a matured kind 3
        _executeAll(_one(_decide(S.KIND_SEATS, P.seat1(0, G[0]))));
        if (!refunds) {
            // nobody's route flag stands; an unpause clears the stale records (none stands, so nothing changes)
            vm.prank(address(admin));
            try ctl.unpauseRoute(live, uint64(vm.getBlockNumber()) + 1) { } catch { }
        }
    }

    // ------------------------------------------------------------------------------------- round 20 actions --

    /// @notice A delivered success and a hidden refund, both in a suspect interval (prepared: 200 held against 150);
    /// A proven delivered, B proven owed (in either order); the verifier then migrated (both proofs void). Checked
    /// right after the delivered proof (it releases nothing), and B settled before A is proven again must not pay.
    function deliveredVoidSibling(bool bFirst) public {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        address p = deliveredToken;
        _limits(p);
        if (!_send(alice, p, 100, true) || !_send(alice, p, 100, false)) return;
        uint256 a = packets.length - 2;
        this.relay(a, false, false); // A: delivered, its honest success ack
        this.relay(a + 1, true, false); // B: a forged success ack hides its refund
        if (!ghost[a + 1].forgedSuccess) return;
        address escrow = ics20.getEscrow(_live());
        uint256 bal = IERC20(p).balanceOf(escrow);
        uint256 reserved = ctl.reserved(_live(), p);
        if (bal < reserved + 150) return;
        if (bal - reserved - 150 != 0 && !_receiveToken(p, bal - reserved - 150, true)) return;
        string memory c = packets[a].sourceClient;
        if (!_replace(true) || !_prepare(c, 1000)) {
            _ensureOpen();
            return;
        }
        if (bFirst && !_prove(a + 1, 0)) return;
        if (!_prove(a, 0)) return; // A proven delivered: still held
        _checkpoint();
        if (!bFirst && !_prove(a + 1, 0)) return;
        MockLightClient fresh = new MockLightClient();
        string memory live = _live();
        if (!_executeAll(
                _one(
                    _decide(
                        S.KIND_CLIENT,
                        P.client(
                            2,
                            live,
                            router.getCounterparty(live).clientId,
                            _prefix(),
                            address(fresh),
                            address(fresh).codehash
                        )
                    )
                )
            )) {
            _ensureOpen();
            return;
        }
        ctl.voidOutcome(c, packets[a].sequence);
        if (!_prove(a + 1, 0)) return;
        T.SettleItem[] memory items = new T.SettleItem[](1);
        items[0] = _action(a + 1);
        if (_settleBatch(c, items, 1) && ctl.sendRecord(c, packets[a + 1].sequence).refunded == 0) {
            ok[bFirst ? "deliveredVoidHeldReversed" : "deliveredVoidHeld"]++;
        }
        _ensureOpen();
    }

    /// @notice The epoch notices, interleaved with the replacements and recoveries that send them: a recorded notice
    /// (of any epoch, acknowledged or not, over its own client even once retired) re-sent, then answered by gno.land's
    /// switched ack, an error ack, or a timeout. Only the switched (or duplicate) ack marks it acknowledged, once; a
    /// resend never fails and never changes the epoch. A notice over a retired (frozen) client cannot be answered.
    function noticeStep(uint256 seed) public {
        calls++;
        _ratchet();
        uint32 top = admin.epoch();
        if (top < 2) return;
        uint32 ep = uint32(2 + (seed & 0xffff) % (top - 1));
        bytes memory notice = admin.epochNotice(ep);
        assertEq(notice.length != 0, true, "every opened epoch's notice recorded");
        string memory gc = admin.govClient();
        vm.recordLogs();
        admin.resendEpochNotice(ep); // always: acknowledged or not, retired client or not
        assertEq(admin.epoch(), top, "a resend changes no epoch");
        assertEq(admin.govClient(), gc, "nor the client");
        if (noticeAckedGhost[ep]) ok["noticeResentAfterAck"]++;
        if (ep != top) ok["noticeResentOld"]++;
        IICS26RouterMsgs.Packet memory pkt;
        bool sent;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].emitter == address(router) && logs[k].topics[0] == IICS26Router.SendPacket.selector) {
                pkt = abi.decode(logs[k].data, (IICS26RouterMsgs.Packet));
                sent = true;
            }
        }
        if (!sent) return;
        assertEq(pkt.payloads[0].value, notice, "the same bytes");
        ok["noticeResent"]++;
        uint256 how = (seed >> 16) % 3;
        if (how == 2) {
            MockLightClient c = MockLightClient(address(router.getClient(pkt.sourceClient)));
            try c.setTimestamp(pkt.timeoutTimestamp) {
                try router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(pkt, "", IICS02ClientMsgs.Height(0, 1))) {
                    ok["noticeTimedOut"]++;
                } catch { }
                c.setTimestamp(0);
            } catch { }
        } else {
            bytes memory ack = how == 0
                ? abi.encodePacked(ep, uint64(0), uint8(1 + 2 * ((seed >> 24) % 2)), uint8(0))  // switched or duplicate
                : ICS24Host.UNIVERSAL_ERROR_ACK;
            try router.ackPacket(IICS26RouterMsgs.MsgAckPacket(pkt, ack, "", IICS02ClientMsgs.Height(0, 1))) {
                if (how == 0) {
                    ok["noticeAcked"]++;
                    noticeAckedGhost[ep] = true;
                }
            } catch { }
        }
        // only a switched (or duplicate) ack ever marks it, and nothing unmarks it
        assertEq(admin.epochNoticeAcked(ep), noticeAckedGhost[ep], "acknowledged iff gno.land's switch landed");
        _checkpoint();
    }

    // ------------------------------------------------------------------------------------- round 19 actions --

    /// @notice Three refunds a forged success ack hid, proven owed (300 reserved) against 150; the verifier then
    /// migrated (every proof void); two outcomes voided by anyone, only the first proven again and settled. Their
    /// liabilities outlive the void: the first must not pay, the others' backing held.
    function voidAndReprove() public {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        address p = voidToken;
        _limits(p);
        if (!_send(alice, p, 100, false) || !_send(alice, p, 100, false) || !_send(alice, p, 100, false)) return;
        uint256 a = packets.length - 3;
        for (uint256 k = 0; k < 3; k++) {
            this.relay(a + k, true, false);
            if (!ghost[a + k].forgedSuccess) return;
        }
        address escrow = ics20.getEscrow(_live());
        uint256 bal = IERC20(p).balanceOf(escrow);
        uint256 reserved = ctl.reserved(_live(), p);
        if (bal < reserved + 150) return;
        if (bal - reserved - 150 != 0 && !_receiveToken(p, bal - reserved - 150, true)) return;
        string memory c = packets[a].sourceClient;
        if (!_replace(true)) return;
        for (uint256 k = 0; k < 3; k++) {
            if (!_prove(a + k, 0)) {
                _ensureOpen();
                return;
            }
        }
        // the verifier migrated: every proof void
        MockLightClient fresh = new MockLightClient();
        string memory live = _live();
        if (!_executeAll(
                _one(
                    _decide(
                        S.KIND_CLIENT,
                        P.client(
                            2,
                            live,
                            router.getCounterparty(live).clientId,
                            _prefix(),
                            address(fresh),
                            address(fresh).codehash
                        )
                    )
                )
            )) {
            _ensureOpen();
            return;
        }
        uint256 held = ctl.reserved(_live(), p);
        ctl.voidOutcome(c, packets[a + 1].sequence);
        ctl.voidOutcome(c, packets[a + 2].sequence);
        assertEq(ctl.reserved(_live(), p), held, "a void keeps the liabilities");
        if (!_prove(a, 0)) {
            _ensureOpen();
            return;
        }
        T.SettleItem[] memory items = new T.SettleItem[](1);
        items[0] = _action(a);
        if (items[0].action == 1 && _settleBatch(c, items, 1) && ctl.sendRecord(c, packets[a].sequence).refunded == 0) {
            ok["voidReproveHeld"]++;
        }
        _ensureOpen();
    }

    // ------------------------------------------------------------------------------------- round 17 actions --

    /// @notice A governance delivery at a chosen number (the packet, for a later relay of the same bytes).
    function _govAt(uint64 seq, uint8 kind, bytes memory params) internal returns (IICS26RouterMsgs.Packet memory) {
        return _govPacket(abi.encodePacked(uint8(1), admin.epoch(), seq, kind, params));
    }

    function _relayGov(IICS26RouterMsgs.Packet memory pkt) internal returns (bool) {
        try router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(pkt, "", IICS02ClientMsgs.Height(0, 1))) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice A tightening (kind 4 lowering a loss token's maximum per message, or kind 11 lengthening the live
    /// route's quarantine), applied at recording. `mode`: 0 delivered in order; 1 buffered beyond one drain, then
    /// recorded by `drain()`; 2 relayed and drained from inside a token hook (refused whole, nothing recorded), then
    /// relayed again outside, where it applies. The controls change exactly, the decision is executed at recording.
    function tightenAtRecording(uint256 mode, bool quarantine) public {
        calls++;
        _ratchet();
        mode = mode % 3;
        if (!_ensureOpen()) return;
        while (admin.drain() != 0) { }
        string memory live = _live();
        address tok = tokens[LOSS_TOKENS];
        _limits(tok);
        T.Limits memory cur = ctl.limits(live, tok).limits;
        uint64 q = ctl.quarantineSeconds(live);
        bytes memory params = quarantine
            ? P.settings(live, q + 1)
            : P.limits(live, tok, cur.maxPerMessage - 1, cur.dayCap, cur.refundCap, cur.sendMax, cur.sendMin);
        uint8 kind = quarantine ? S.KIND_SETTINGS : S.KIND_LIMITS;
        uint64 last = admin.lastSeq();
        uint64 seq = last + 1;
        if (mode == 1) {
            // DRAIN + 1 harmless decisions first, buffered, then the tightening behind them
            seq = last + uint64(S.DRAIN) + 2;
            for (uint64 k = last + 2; k < seq; k++) {
                if (!_relayGov(_govAt(k, S.KIND_UNPAUSE, P.unpause(1, live)))) return;
            }
        }
        IICS26RouterMsgs.Packet memory tight = _govAt(seq, kind, params);
        if (mode == 2) {
            // from inside a send's token hook: the delivery reverts whole, the drain records nothing
            if (ics20.getEscrow(live) == address(0) && !_send(alice, address(hookToken), 1, true)) return;
            hookToken.setHook(
                ics20.getEscrow(live),
                address(router),
                abi.encodeCall(
                    router.recvPacket, (IICS26RouterMsgs.MsgRecvPacket(tight, "", IICS02ClientMsgs.Height(0, 1)))
                )
            );
            _limits(address(hookToken));
            if (!_send(alice, address(hookToken), 1, true)) {
                hookToken.setHook(address(0), address(0), "");
                return;
            }
            hookToken.setHook(address(0), address(0), "");
            bool unchanged = !hookToken.hookOk() && admin.lastSeq() == last
                && (quarantine
                        ? ctl.quarantineSeconds(live) == q
                        : ctl.limits(live, tok).limits.maxPerMessage == cur.maxPerMessage);
            if (!unchanged) return;
            ok["tightenInHookRefused"]++;
        }
        if (!_relayGov(tight)) return;
        if (mode == 1) {
            if (admin.decision(admin.epoch(), seq).state != S.BUFFERED) return; // the drain bound left it buffered
            // the gap filled: the first relayed now records it and DRAIN after it; the rest by drain()
            if (!_relayGov(_govAt(last + 1, S.KIND_UNPAUSE, P.unpause(1, live)))) return;
            while (admin.drain() != 0) { }
        }
        IIBCAdmin.Decision memory dec = admin.decision(admin.epoch(), seq);
        bool applied = quarantine
            ? ctl.quarantineSeconds(live) == q + 1
            : ctl.limits(live, tok).limits.maxPerMessage == cur.maxPerMessage - 1;
        assertTrue(applied && dec.state == S.EXECUTED, "a tightening applies at recording");
        ok[mode == 0 ? "tightenDelivery" : (mode == 1 ? "tightenDrain" : "tightenAfterHook")]++;
        _checkpoint();
    }

    /// @notice A timeout of an unsettled record of a retired client (its freeze defeated for this one call, test
    /// only): it reaches the callback, joins the client's processed history as suspect work, and its refund is
    /// paid or owed.
    function retiredTimeout(uint256 i) public {
        calls++;
        _ratchet();
        if (packets.length == 0) return;
        i = i % packets.length;
        IICS26RouterMsgs.Packet memory pkt = packets[i];
        if (ghost[i].relayed || ghost[i].delivered || !ctl.isRetired(pkt.sourceClient) || !ctl.routeClosed(_live())) {
            return;
        }
        T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        if (rec.settlement != 0 || rec.outcome != T.Outcome.Pending) return;
        (,,, uint64 suspect0, uint64 processed0) = ctl.clientRecon(pkt.sourceClient);
        address frozen = address(router.getClient(pkt.sourceClient));
        bytes memory code = frozen.code;
        vm.etch(frozen, address(new MockLightClient()).code);
        MockLightClient(frozen).setTimestamp(pkt.timeoutTimestamp);
        bool done;
        try router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(pkt, "", IICS02ClientMsgs.Height(0, 1))) {
            done = true;
        } catch { }
        MockLightClient(frozen).setTimestamp(0);
        vm.etch(frozen, code); // frozen again
        if (!done) return;
        _relayed(i);
        T.SendRecord memory after_ = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        (,,, uint64 suspect1, uint64 processed1) = ctl.clientRecon(pkt.sourceClient);
        assertEq(uint8(after_.outcome), uint8(T.Outcome.Timeout), "the timeout reached the callback");
        assertEq(processed1, processed0 + 1, "processed history");
        assertEq(suspect1, suspect0 + 1, "suspect work of the incident");
        assertTrue(
            after_.refunded == after_.amount || after_.payment == T.Payment.Queued
                || after_.payment == T.Payment.Parked,
            "the refund paid or owed"
        );
        ok["retiredTimeout"]++;
        _checkpoint();
    }

    /// @notice Two refunds a forged success ack hid, owed again in ONE kind 12 (in either order) against 150 of
    /// backing: both are reserved before either is paid, so neither payment may proceed (it would take the
    /// other's backing).
    function twinHiddenInitial(bool reversed, bool separate) public {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        address p = twinInitialToken;
        _limits(p);
        if (!_send(alice, p, 100, false) || !_send(alice, p, 100, false)) return;
        uint256 a = packets.length - 2;
        this.relay(a, true, false);
        this.relay(a + 1, true, false);
        if (!ghost[a].forgedSuccess || !ghost[a + 1].forgedSuccess) return;
        address escrow = ics20.getEscrow(_live());
        uint256 bal = IERC20(p).balanceOf(escrow);
        uint256 reserved = ctl.reserved(_live(), p);
        if (bal < reserved + 150) return;
        if (bal - reserved - 150 != 0 && !_receiveToken(p, bal - reserved - 150, true)) return;
        string memory c = packets[a].sourceClient;
        if (!_replace(true) || !_prove(a, 0) || !_prove(a + 1, 0)) {
            _ensureOpen();
            return;
        }
        T.SettleItem[] memory items = new T.SettleItem[](2);
        items[reversed ? 1 : 0] = _action(a);
        items[reversed ? 0 : 1] = _action(a + 1);
        bool settled;
        if (items[0].action == 1 && items[1].action == 1) {
            if (separate) {
                // two decisions: the second refund was reserved by its proof, before the first decision
                T.SettleItem[] memory one = new T.SettleItem[](1);
                one[0] = items[0];
                settled = _settleBatch(c, one, 1);
                one[0] = items[1];
                settled = settled && _settleBatch(c, one, 1);
            } else {
                settled = _settleBatch(c, items, 2);
            }
        }
        T.SendRecord memory ra = ctl.sendRecord(c, packets[a].sequence);
        T.SendRecord memory rb = ctl.sendRecord(c, packets[a + 1].sequence);
        if (settled && ra.refunded == 0 && rb.refunded == 0 && ra.settlement == 1 && rb.settlement == 1) {
            ok[separate ? "twinInitialHeldSeparate" : (reversed ? "twinInitialHeldReversed" : "twinInitialHeld")]++;
        }
        _ensureOpen();
    }

    // ------------------------------------------------------------------------------------- round 16 actions --

    /// @notice Two refunds a forged success ack hid, both owed again by reconciliation and unpaid against too little
    /// backing; the backing then replenished in part (a delivered send acknowledged: gno.land holds those tokens).
    /// A retry of one of them must not take the other's backing.
    function twinEligibleRefunds() external {
        calls++;
        _ratchet();
        if (clients.length >= 64 || !_ensureOpen()) return;
        address p = twinToken;
        _limits(p);
        if (!_send(alice, p, 100, false) || !_send(alice, p, 100, false)) return;
        uint256 a = packets.length - 2;
        this.relay(a, true, false);
        this.relay(a + 1, true, false); // two forged success acks: both reservations released
        if (!ghost[a].forgedSuccess || !ghost[a + 1].forgedSuccess) return;
        address escrow = ics20.getEscrow(_live());
        uint256 bal = IERC20(p).balanceOf(escrow);
        uint256 reserved = ctl.reserved(_live(), p);
        if (bal < reserved + 50) return;
        if (bal - reserved - 50 != 0 && !_receiveToken(p, bal - reserved - 50, true)) return;
        if (!_replace(true)) return;
        _reconcile(0, true); // both owed again: 200 against 50
        if (!_reopen()) {
            _ensureOpen();
            return;
        }
        // replenished: a delivered send of 100, acknowledged (no reservation: gno.land holds it)
        if (!_send(alice, p, 100, true)) return;
        this.relay(packets.length - 1, false, false);
        T.SendRecord memory ra = ctl.sendRecord(packets[a].sourceClient, packets[a].sequence);
        T.SendRecord memory rb = ctl.sendRecord(packets[a + 1].sourceClient, packets[a + 1].sequence);
        if (ra.settlement != 1 || rb.settlement != 1 || ra.refunded != 0 || rb.refunded != 0) {
            _ensureOpen();
            return;
        }
        // 150 against two reservations of 100: a retry of either must leave the other's 100 backed
        try ctl.claim(_live(), p, 20) { } catch { }
        try ctl.claimParked(packets[a].sourceClient, packets[a].sequence, 300_000) { } catch { }
        uint256 paid = ctl.sendRecord(packets[a].sourceClient, packets[a].sequence).refunded
            + ctl.sendRecord(packets[a + 1].sourceClient, packets[a + 1].sequence).refunded;
        _checkpoint(); // the payments' postconditions, if any was made
        if (paid == 0) ok["twinRefundHeld"]++;
        _ensureOpen();
    }

    // ----------------------------------------------------------------------------------- coverage sweep --

    /// @notice Runs each required composite once after the random sequence when the sequence did not.
    function sweep() external {
        if (ok["deliveredVoidHeld"] == 0) deliveredVoidSibling(false);
        if (ok["deliveredVoidHeldReversed"] == 0) deliveredVoidSibling(true);
        if (ok["noticeTimedOut"] == 0 && clients.length < 64 && _ensureOpen() && _replace(true)) {
            noticeStep((uint256(2) << 16) | (admin.epoch() - 2)); // the latest epoch's notice, timed out
        }
        if (ok["noticeAcked"] == 0 && clients.length < 64 && _ensureOpen() && _replace(true)) {
            noticeStep(admin.epoch() - 2); // the latest epoch's notice, switched
        }
        if (ok["noticeResentAfterAck"] == 0) {
            // an acknowledged notice re-sent (then answered by an error ack, which unmarks nothing)
            for (uint32 e = 2; e <= admin.epoch(); e++) {
                if (noticeAckedGhost[e]) {
                    noticeStep((uint256(1) << 16) | (e - 2));
                    break;
                }
            }
        }
        if (ok["noticeResentOld"] == 0) {
            for (uint256 k = 0; k < 2 && admin.epoch() < 3 && clients.length < 64 && _ensureOpen(); k++) {
                _replace(true);
            }
            if (admin.epoch() >= 3) noticeStep(uint256(1) << 16); // epoch 2's, a newer one current
        }
        if (ok["preparePartial"] == 0 && _ensureOpen() && clients.length < 64) {
            // two successes processed, the route replaced from 0, then a batch of one: partial, then the rest
            if (_send(alice, tokens[0], 5, true) && _send(alice, tokens[0], 6, true)) {
                this.relay(packets.length - 2, false, false);
                this.relay(packets.length - 1, false, false);
                string memory c = packets[packets.length - 1].sourceClient;
                if (_replace(true)) {
                    _prepare(c, 1);
                    _checkpoint();
                    _prepare(c, 1000);
                }
            }
            _ensureOpen();
        }
        if ((ok["prepared"] == 0 || ok["proveAndPay"] == 0) && _ensureOpen() && clients.length < 64) {
            if (_send(alice, tokens[0], 5, false)) {
                uint256 i = packets.length - 1;
                this.relay(i, true, false); // a forged success ack: suspect once the client is retired
                string memory c = packets[i].sourceClient;
                if (_replace(true)) {
                    this.proveAndPay(i, 0); // proven and settled before the preparation: parked
                    _prepare(c, 1000);
                }
            }
            _ensureOpen();
        }
        if (ok["voidReproveHeld"] == 0) voidAndReprove();
        if (ok["tightenDelivery"] == 0) tightenAtRecording(0, false);
        if (ok["tightenDrain"] == 0) tightenAtRecording(1, true);
        if (ok["tightenAfterHook"] == 0 || ok["tightenInHookRefused"] == 0) tightenAtRecording(2, false);
        if (ok["retiredTimeout"] == 0 && _ensureOpen() && clients.length < 64) {
            _send(alice, tokens[0], 3, false);
            if (_replace(true)) retiredTimeout(packets.length - 1);
            _ensureOpen();
        }
        if (ok["twinInitialHeld"] == 0) twinHiddenInitial(false, false);
        if (ok["twinInitialHeldReversed"] == 0) twinHiddenInitial(true, false);
        if (ok["twinInitialHeldSeparate"] == 0) twinHiddenInitial(false, true);
        if (ok["twinRefundHeld"] == 0) this.twinEligibleRefunds();
        if (ok["replaceInDipRefunds"] == 0) replaceDuringDip(true);
        if (ok["replaceInDipRoute"] == 0) replaceDuringDip(false);
        if (ok["olderRefundHeld"] == 0) this.partialBacking();
        if (ok["partialBackingHeld"] == 0) this.partialBacking();
        if (ok["lossResolvedIncidentSealed"] == 0) this.lossResolvedIncidentDuringReopening();
        if (ok["continueNonTerminal"] == 0) {
            _startLongReopening();
            _ensureOpen();
        }
        if (ok["prematureReopenRefused"] == 0 && _ensureOpen() && clients.length < 64) {
            _send(alice, tokens[0], 4, false); // outstanding: an open record
            if (_replace(true)) prematureReopen();
            _ensureOpen();
        }
        if (ok["lateOnSettledIgnored"] == 0 && _ensureOpen() && clients.length < 64) {
            _send(alice, tokens[0], 3, false);
            _send(alice, tokens[0], 2, true);
            uint256 a = packets.length - 2;
            if (_replace(true)) {
                _reconcile(0, true); // both settled while outstanding (a refund, a delivery)
                lateOnSettled(a, true);
                lateOnSettled(a + 1, false);
            }
            _ensureOpen();
        }
        if (ok["provenAckReplaced"] == 0) this.forgedSuccessAck(9);
        if (ok["approvalWithdrawn"] == 0) this.withdrawApproval();
        if (ok["retiredAck"] == 0 && _ensureOpen() && clients.length < 64) {
            _send(alice, tokens[0], 5, true);
            _send(alice, tokens[0], 6, false);
            if (_replace(true)) {
                this.retiredAck(packets.length - 2);
                this.retiredAck(packets.length - 1);
            }
            _ensureOpen();
        }
        if (ok["settleExpiredRefused"] == 0 || ok["settleStaleGenRefused"] == 0) staleSettlements(0x1);
        if (ok["adapterRefused"] == 0) {
            _ensureOpen();
            this.adapterRefuses(7);
        }
        if (ok["sendVoucher"] == 0) {
            _ensureOpen();
            if (ugnot.balanceOf(bob) == 0) this.receiveVoucher(50, false);
            this.sendVoucher(3, true);
        }
        if (ok["authoritySuspended"] == 0) this.recoverWithAuthorityAttempts();
        if (ok["lossDuringReopeningRefused"] == 0) {
            _ensureOpen();
            this.lossDuringReopening(3);
            _ensureOpen();
        }
        if (ok["abortInjected"] == 0) {
            this.faultInjectedAbort();
            _ensureOpen();
        }
        if (ok["startReplacement"] == 0 || ok["executePending"] == 0) {
            _ensureOpen();
            this.startReplacement(true);
            this.executePending();
        }
        if (ok["proveOne"] == 0 || ok["decideSettle"] == 0 || ok["startReopen"] == 0) {
            _ensureOpen();
            if (!ctl.routeClosed(_live()) && clients.length < 64) {
                _send(alice, tokens[0], 5, false);
                _replace(true);
            }
            for (uint256 i = 0; i < packets.length && ok["proveOne"] == 0; i++) {
                this.proveOne(i, 0);
            }
            for (uint256 i = 0; i < packets.length && ok["decideSettle"] == 0; i++) {
                if (!ctl.isRetired(packets[i].sourceClient)) continue;
                T.SendRecord memory rec = ctl.sendRecord(packets[i].sourceClient, packets[i].sequence);
                if (rec.settlement != 0) continue;
                if (_prove(i, 0)) this.decideSettle(i);
            }
            this.executePending();
            this.startReopen();
            this.executePending();
        }
        if (
            ok["mismatchRefused"] == 0 || ok["settleStaleRefused"] == 0 || ok["replayRefused"] == 0
                || ok["recoveryCancelled"] == 0
        ) {
            adversarialRound(0x2);
        }
        if (ok["senderReentryRefused"] == 0) {
            _ensureOpen();
            this.senderReentry(5);
        }
        if (ok["receiveVoucher"] == 0) {
            _ensureOpen();
            this.receiveVoucher(10, true);
        }
        if (ok["transportRound"] == 0) transportRound(0xA5A5A5);
        if (ok["lateLoss"] == 0) lateLossScenario();
        if (ok["replace"] == 0 && clients.length < 6 && _replace(true)) ok["replace"]++;
        if (ok["reconcile"] == 0 && _reconcile(0, true)) ok["reconcile"]++;
        if (ctl.routeClosed(_live()) && !ctl.routeReopening(_live())) _reopen();
        if (ok["busyGovernance"] == 0) {
            _ensureOpen();
            this.busyGovernance(3);
        }
        if (ok["replaceDuringReopening"] == 0) this.replaceDuringReopening();
        // the aborted reopening reconciled and reopened again: its deficits need the continuation
        if (ctl.routeClosed(_live()) && !ctl.routeReopening(_live())) {
            _reconcile(0, true);
            _reopen();
        }
        for (uint256 i = 0; i < 32 && ctl.routeReopening(_live()); i++) {
            if (_continue(true)) ok["continueReopen"]++;
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
        h.setVoucher(ugnot);
        h.setChecker(ICheckpoint(address(this)));
        vm.prank(alice);
        usdc.approve(address(ics20), type(uint256).max);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = ReconcileHandler.sweep.selector;
        sel[1] = ReconcileHandler.setVoucher.selector;
        sel[2] = ReconcileHandler.setChecker.selector;
        sel[3] = ReconcileHandler.probeSetPacket.selector;
        excludeSelector(FuzzSelector(address(h), sel));
    }

    /// @notice The reservation a record's state calls for, from the packet's own amount (the ghost's).
    function _reserveOf(T.SendRecord memory rec, uint256 i) internal view returns (uint256) {
        return _burnedOf(i) ? 0 : _entitlement(rec, i);
    }

    /// @notice Whether packet `i` burned a voucher rather than escrowing a native token, from the ghost's own token
    /// origin (the voucher gno.land's ugnot mints), never from the record's flag; the authenticated packet's full
    /// denom must be the one that origin calls for.
    function _burnedOf(uint256 i) internal view returns (bool) {
        (,,,,, address gtoken,) = h.ghost(i);
        IICS20TransferMsgs.FungibleTokenPacketData memory data =
            abi.decode(h.packet(i).payloads[0].value, (IICS20TransferMsgs.FungibleTokenPacketData));
        require(
            keccak256(bytes(data.denom)) == keccak256(bytes(_wireDenom(i))),
            "the packet's denom is the ghost's wire denom"
        );
        return gtoken == address(ugnot);
    }

    /// @notice The full wire denom of send `i`, from the ghost's inputs alone: a native token its address in
    /// lowercase hex; gno.land's ugnot voucher, returning to its source, `transfer/<the client the send named>/ugnot`.
    function _wireDenom(uint256 i) internal view returns (string memory) {
        (,,,,, address gtoken,) = h.ghost(i);
        if (gtoken == address(ugnot)) return string.concat("transfer/", h.sentOver(i), "/ugnot");
        return Strings.toHexString(gtoken);
    }

    /// @notice What the record still owes its sender: escrowed tokens reserved, or vouchers to mint again (a burn).
    /// @notice What record `i` still owes its sender, from the ghost's transport history and governance's settlements
    /// (never the record's outcome or payment state): unsettled and never relayed, its whole amount (outstanding); a
    /// refund outcome, or a settlement as a refund (action 1), its unpaid remainder; a success held as a potential
    /// refund, its remainder; anything else, nothing. The amount refunded is the record's, which payment
    /// conservation checks against the balances.
    function _entitlement(T.SendRecord memory rec, uint256 i) internal view returns (uint256) {
        (bool delivered, bool forgedSuccess, bool forgedRefund, bool relayed,,, uint256 amount) = h.ghost(i);
        bytes32 key = keccak256(abi.encode(h.packet(i).sourceClient, h.packet(i).sequence));
        uint8 action = h.settledAction(key);
        if (action == 1) return amount - rec.refunded;
        if (action != 0) return 0;
        if (!relayed) return amount;
        bool success = forgedSuccess || (delivered && !forgedRefund);
        if (!success) return amount - rec.refunded;
        return h.heldGhost(i) ? amount - rec.refunded : 0;
    }

    /// @notice The record's outcome agrees with the ghost's transport history: pending exactly when never relayed
    /// (or relayed only after a settlement, which ignored it), a success exactly when the relay was one.
    function _checkOutcome(T.SendRecord memory rec, uint256 i) internal view {
        (bool delivered, bool forgedSuccess, bool forgedRefund, bool relayed,,,) = h.ghost(i);
        bytes32 key = keccak256(abi.encode(h.packet(i).sourceClient, h.packet(i).sequence));
        bool processed = relayed && !h.ignoredRelay(i);
        assertEq(rec.outcome != T.Outcome.Pending, processed, "outcome pending iff never processed (the ghost's)");
        if (processed) {
            bool success = forgedSuccess || (delivered && !forgedRefund);
            assertEq(rec.outcome == T.Outcome.Success, success, "outcome a success iff the relay was one");
        }
        key;
    }

    /// @notice The record is bound to its packet: the token, sender and amount the handler sent, which the packet the
    /// router committed (and emitted) carries too. The packet's metadata is derived independently from the ghost's
    /// send inputs: the client the send named, the canonical sender (lowercase hex) and the full wire denom.
    function _checkBinding(IICS26RouterMsgs.Packet memory pkt, T.SendRecord memory rec, uint256 i) internal view {
        (,,,, address sender, address token, uint256 amount) = h.ghost(i);
        IICS20TransferMsgs.FungibleTokenPacketData memory data =
            abi.decode(pkt.payloads[0].value, (IICS20TransferMsgs.FungibleTokenPacketData));
        require(
            keccak256(bytes(pkt.sourceClient)) == keccak256(bytes(h.sentOver(i))), "the packet's client is the send's"
        );
        require(
            keccak256(bytes(data.sender)) == keccak256(bytes(Strings.toHexString(sender))),
            "the packet's sender is the ghost's canonical sender"
        );
        require(
            keccak256(bytes(data.denom)) == keccak256(bytes(_wireDenom(i))),
            "the packet's denom is the ghost's wire denom"
        );
        require(keccak256(bytes(data.receiver)) == keccak256("g1receiver"), "the packet's receiver is the send's");
        assertEq(data.amount, amount, "the packet carries the amount sent");
        assertEq(rec.amount, amount, "the record's amount is the packet's");
        assertEq(rec.token, token, "the record's token is the packet's");
        assertEq(rec.sender, sender, "the record's sender is the packet's");
        assertEq(rec.commitment, ICS24Host.packetCommitmentBytes32(pkt), "the record's commitment is the packet's");
    }

    function _resolved(string memory client) internal view returns (bool) {
        (, uint32 incident,,,) = ctl.clientRecon(client);
        (, uint64 resolvedUpTo,) = ctl.incidents(clientId);
        return incident != 0 && incident - 1 < resolvedUpTo;
    }

    /// @notice Boundary seeds: no handler action reverts on the extremes of its inputs (seeds are normalized
    /// before any arithmetic).
    /// @notice r18 #2, a corruption probe: an outstanding native send whose record is flipped to `burned` (its
    /// reservation dropped) must fail the oracle at once, from the ghost's independent classification.
    function test_r18_2_burnedFlagCorruption_failsAtOnce() public {
        h.send(0, 40, true); // usdc, outstanding
        IICS26RouterMsgs.Packet memory pkt = h.packet(0);
        this.checkpoint();
        // find the record's `burned` bit: flip each word the record view reads and watch the flag
        vm.record();
        ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        (bytes32[] memory reads,) = vm.accesses(address(ics20));
        for (uint256 k = 0; k < reads.length; k++) {
            if (reads[k] == 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc) continue; // the proxy's
            bytes32 orig = vm.load(address(ics20), reads[k]);
            for (uint256 b = 0; b < 256; b += 8) {
                vm.store(address(ics20), reads[k], bytes32(uint256(orig) | (uint256(1) << b)));
                (bool okCall, bytes memory ret) =
                    address(ctl).staticcall(abi.encodeCall(ctl.sendRecord, (pkt.sourceClient, pkt.sequence)));
                if (
                    okCall && ret.length == 32 * 19 && abi.decode(ret, (T.SendRecord)).burned
                        && uint256(orig) & (uint256(1) << b) == 0
                ) {
                    // corrupted: the oracle must refuse it now
                    vm.expectRevert(bytes("burned iff the ghost's token is a voucher: true != false"));
                    this.checkpoint();
                    return;
                }
                vm.store(address(ics20), reads[k], orig);
            }
        }
        revert("the burned bit not found");
    }

    /// @notice r23, redirection probes: a refund the record shows paid to its contract sender, moved afterwards to
    /// another party (the adapter, or the adapter's owner) with every total unchanged. The oracle checks each party
    /// on its own and must reject it at once.
    function test_r23_reentrantRefundRedirected_failsAtOnce() public {
        h.senderReentry(5);
        uint256 i = h.packetCount() - 1;
        IICS26RouterMsgs.Packet memory pkt = h.packet(i);
        assertEq(ctl.sendRecord(pkt.sourceClient, pkt.sequence).refunded, 5, "refunded to the re-entrant sender");
        this.checkpoint();
        address re = address(h.reentrant());
        IERC20 token = IERC20(h.tokens(2));
        address ad = h.adapterAddress();
        vm.prank(re);
        token.transfer(ad, 5); // as if the refund had gone to the adapter
        vm.expectRevert(bytes("the re-entrant sender's tokens: 0 != 5"));
        this.checkpoint();
    }

    function test_r23_adapterRefundRedirectedToOwner_failsAtOnce() public {
        h.sendFromAdapter(7, false);
        uint256 i = h.packetCount() - 1;
        IICS26RouterMsgs.Packet memory pkt = h.packet(i);
        h.relay(i, false, true); // a timeout: refunded to the adapter, which forwards it to its owner
        assertEq(ctl.sendRecord(pkt.sourceClient, pkt.sequence).refunded, 7);
        this.checkpoint();
        // a second refund of 7 the adapter kept, then moved to the owner outside a forward
        SenderAdapter ad = SenderAdapter(h.adapterAddress());
        h.sendFromAdapter(7, false);
        i = h.packetCount() - 1;
        pkt = h.packet(i);
        ad.setRefuse(true); // the callback fails: the refund stays with the adapter, not forwarded
        h.relay(i, false, true);
        ad.setRefuse(false);
        assertEq(ctl.sendRecord(pkt.sourceClient, pkt.sequence).refunded, 7);
        this.checkpoint();
        address owner = ad.owner();
        vm.prank(address(ad));
        usdc.transfer(owner, 7);
        vm.expectRevert(bytes("the adapter's tokens: 0 != 7"));
        this.checkpoint();
    }

    /// @notice r22 #1, corruption probes: packet 0's sender or denom substituted while the record's commitment is
    /// moved to the substituted packet (consistent with it), amount and everything else unchanged. The oracle must
    /// reject both from the ghost's own send inputs.
    function test_r22_1_senderSubstituted_failsAtOnce() public {
        _substitute(true);
    }

    function test_r22_1_denomSubstituted_failsAtOnce() public {
        _substitute(false);
    }

    function _substitute(bool sender) internal {
        h.send(0, 40, true); // usdc, outstanding
        IICS26RouterMsgs.Packet memory pkt = h.packet(0);
        this.checkpoint();
        bytes32 old = ICS24Host.packetCommitmentBytes32(pkt);
        IICS20TransferMsgs.FungibleTokenPacketData memory data =
            abi.decode(pkt.payloads[0].value, (IICS20TransferMsgs.FungibleTokenPacketData));
        if (sender) data.sender = Strings.toHexString(bob);
        else data.denom = Strings.toHexString(h.tokens(1));
        pkt.payloads[0].value = abi.encode(data);
        bytes32 forged = ICS24Host.packetCommitmentBytes32(pkt);
        // the record's commitment moved to the substituted packet
        vm.record();
        ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        (bytes32[] memory reads,) = vm.accesses(address(ics20));
        bool moved;
        for (uint256 k = 0; k < reads.length && !moved; k++) {
            if (vm.load(address(ics20), reads[k]) == old) {
                vm.store(address(ics20), reads[k], forged);
                moved = true;
            }
        }
        assertTrue(moved, "the commitment slot not found");
        assertEq(ctl.sendRecord(pkt.sourceClient, pkt.sequence).commitment, forged);
        h.probeSetPacket(0, pkt);
        vm.expectRevert(
            bytes(
                sender
                    ? "the packet's sender is the ghost's canonical sender"
                    : "the packet's denom is the ghost's wire denom"
            )
        );
        this.checkpoint();
    }

    /// @notice r21 #2, a corruption probe: an outstanding native send's record set to `Success` and its reservation
    /// dropped must fail the oracle at once, from the ghost's transport history (never relayed).
    function test_r21_2_outcomeCorruption_failsAtOnce() public {
        h.send(0, 40, true); // usdc, outstanding
        IICS26RouterMsgs.Packet memory pkt = h.packet(0);
        this.checkpoint();
        T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        // the route's reservation dropped by the record's amount
        vm.record();
        ctl.reserved(clientId, rec.token);
        (bytes32[] memory rr,) = vm.accesses(address(ics20));
        bool dropped;
        for (uint256 k = 0; k < rr.length && !dropped; k++) {
            uint256 v = uint256(vm.load(address(ics20), rr[k]));
            if (v == rec.amount && rr[k] != 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc) {
                vm.store(address(ics20), rr[k], bytes32(v - rec.amount));
                dropped = ctl.reserved(clientId, rec.token) == 0;
                if (!dropped) vm.store(address(ics20), rr[k], bytes32(v));
            }
        }
        assertTrue(dropped, "the reservation slot not found");
        // the record's outcome set to Success
        vm.record();
        ctl.sendRecord(pkt.sourceClient, pkt.sequence);
        (bytes32[] memory reads,) = vm.accesses(address(ics20));
        for (uint256 k = 0; k < reads.length; k++) {
            if (reads[k] == 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc) continue;
            bytes32 orig = vm.load(address(ics20), reads[k]);
            for (uint256 b = 0; b < 256; b += 8) {
                if (uint256(orig) & (uint256(0xff) << b) != 0) continue;
                vm.store(address(ics20), reads[k], bytes32(uint256(orig) | (uint256(1) << b)));
                (bool okCall, bytes memory ret) =
                    address(ctl).staticcall(abi.encodeCall(ctl.sendRecord, (pkt.sourceClient, pkt.sequence)));
                if (okCall && ret.length == 32 * 19) {
                    T.SendRecord memory r2 = abi.decode(ret, (T.SendRecord));
                    if (r2.outcome == T.Outcome.Success && !r2.burned && r2.open == rec.open && !r2.held) {
                        vm.expectRevert(bytes("outcome pending iff never processed (the ghost's): true != false"));
                        this.checkpoint();
                        return;
                    }
                }
                vm.store(address(ics20), reads[k], orig);
            }
        }
        revert("the outcome byte not found");
    }

    function test_handlerSeedBoundaries() public {
        uint256 max = type(uint256).max;
        h.send(max, max, true);
        h.send(0, 0, false);
        h.sendFromAdapter(max, true);
        h.relay(max, true, true);
        h.relay(0, false, false);
        h.notify(max);
        h.notify(0);
        h.receive_(max, max, true);
        h.receiveVoucher(max, true);
        h.claim(max);
        h.claimParked(max);
        h.refundsFlag(max, true);
        h.replace(true);
        h.reconcile(max, true);
        h.reconcile(max - 2, false);
        h.verifierEvent(max);
        h.warp(max);
        h.lateLoss(max);
        h.senderReentry(max);
        h.busyGovernance(max);
        h.adversarialRound(max);
        h.transportRound(max);
        h.continueReopen();
        h.reopen();
    }

    /// forge-config: default.invariant.runs = 24
    /// (no shrinking: replaying a failure reports its sequence at once; shrinking one takes many minutes)
    /// forge-config: default.invariant.shrink-run-limit = 0
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ghostModel() public view {
        _checkAll();
    }

    /// @notice The same checks, run by the handler between the steps of its composite transitions.
    function checkpoint() external view {
        _checkAll();
    }

    /// @notice r11 #5, Codex's sequence: a forged voucher receive, a replacement and a kind 13, each recorded and
    /// executed by the split steps. Governance reconciles completely before the generated kind 13 executes (the
    /// documented precondition), so the forged receive is booked and every invariant holds.
    function test_r11_5_generatedReopen_reconcilesFirst() public {
        h.receiveVoucher(1, true);
        h.startReplacement(true);
        h.executePending();
        h.startReopen();
        h.executePending();
        ReconcileHandler.Receive memory rv = h.receiveAt(0);
        assertTrue(rv.forged);
        assertTrue(ctl.lossBooked(rv.client, rv.sequence, 2), "booked before the reopening");
        assertFalse(ctl.routeClosed(clientId), "reopened");
        _checkAll();
    }

    struct Flows {
        uint256[] reserve;
        uint256[] refundedAlice;
        uint256[] refundedAdapter;
        uint256[] refundedReentrant;
        uint256[] refundedAll;
        uint256[] loss;
        uint256[] eligibleUnpaid; // the unpaid part of the refunds the shortfall allowance belongs to
    }

    function _flows(uint256 tn) internal pure returns (Flows memory f) {
        f.reserve = new uint256[](tn + 1);
        f.eligibleUnpaid = new uint256[](tn + 1);
        f.refundedAlice = new uint256[](tn + 1);
        f.refundedAdapter = new uint256[](tn + 1);
        f.refundedReentrant = new uint256[](tn + 1);
        f.refundedAll = new uint256[](tn + 1);
        f.loss = new uint256[](tn + 1); // index tn: the ugnot voucher
    }

    function _tokenIndex(address token, uint256 tn) internal view returns (uint256 t) {
        if (token == address(ugnot)) return tn;
        while (t < tn && h.tokens(t) != token) t++;
    }

    function _checkAll() internal view {
        uint256 n = h.packetCount();
        uint256 tn = h.tokenCount();
        bool open = !ctl.routeClosed(clientId);
        Flows memory f = _flows(tn);
        for (uint256 i = 0; i < n; i++) {
            IICS26RouterMsgs.Packet memory pkt = h.packet(i);
            T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
            (bool delivered,,,, address sender, address gtoken, uint256 amount) = h.ghost(i);
            _checkBinding(pkt, rec, i);
            // open iff the commitment is outstanding or a refund is owed; settled iff governance settled it (the
            // ghost's, never the record's own flags)
            (bool expOpen,) = h.expectedOf(i);
            assertEq(rec.open, expOpen, "open iff outstanding or a refund owed");
            assertEq(
                rec.settlement != 0,
                h.settledCount(keccak256(abi.encode(pkt.sourceClient, pkt.sequence))) != 0,
                "settled iff governance settled it"
            );
            uint256 t = _tokenIndex(gtoken, tn);
            _checkOutcome(rec, i);
            uint256 r = _reserveOf(rec, i);
            assertEq(rec.burned, _burnedOf(i), "burned iff the ghost's token is a voucher");
            f.reserve[t] += r;
            if (h.eligible(i)) f.eligibleUnpaid[t] += r;
            f.refundedAll[t] += rec.refunded;
            // each sender's refunds on its own: a refund paid to another party than the record's sender shows
            if (sender == alice) f.refundedAlice[t] += rec.refunded;
            else if (sender == _adapter()) f.refundedAdapter[t] += rec.refunded;
            else if (sender == address(h.reentrant())) f.refundedReentrant[t] += rec.refunded;
            else require(sender == bob && t == tn, "a sender the oracle does not track");
            if (t == tn) require(sender == bob, "only bob sends the voucher");
            // every record settled at most once, never refunded beyond its amount
            assertLe(h.settledCount(keccak256(abi.encode(pkt.sourceClient, pkt.sequence))), 1, "settled once");
            assertLe(rec.refunded, amount, "refunded once");
            // kind 12's actions agree with the truth (the proofs are honest)
            if (rec.settlement == 1) assertFalse(delivered, "a refund settled for a delivered packet");
            if (rec.settlement >= 2) assertTrue(delivered, "a delivered settlement for an undelivered packet");
            // an undelivered record ends refunded in full or still reserved, unless a forged success ack hides it
            // until its incident's reconciliation (the refunds are real: the senders' balances are checked below)
            if (!delivered && rec.refunded != amount && _entitlement(rec, i) != amount - rec.refunded) {
                // (the ghost's: a forged success ack, not settled)
                (, bool forgedSuccess,,,,,) = h.ghost(i);
                assertTrue(
                    forgedSuccess && h.settledAction(keccak256(abi.encode(pkt.sourceClient, pkt.sequence))) == 0
                        && (!_resolved(pkt.sourceClient) || h.leftOutSend(i + 1)),
                    "an undelivered refund neither paid nor reserved"
                );
            }
            // losses, per packet as amounts: a refund paid for a delivered packet, never an undelivered one's
            bool booked = ctl.lossBooked(pkt.sourceClient, pkt.sequence, 1);
            if (!delivered) assertFalse(booked, "a loss booked for an undelivered packet");
            if (booked) f.loss[t] += rec.refunded;
            if (open && delivered && rec.refunded != 0 && _resolved(pkt.sourceClient) && !h.leftOutSend(i + 1)) {
                assertTrue(booked, "a forged refund not booked");
            }
        }
        uint256 m = h.receiveCount();
        for (uint256 j = 0; j < m; j++) {
            ReconcileHandler.Receive memory rv = h.receiveAt(j);
            bool booked = ctl.lossBooked(rv.client, rv.sequence, 2);
            if (!rv.forged) assertFalse(booked, "a loss booked for an honest receive");
            if (booked) f.loss[_tokenIndex(rv.token, tn)] += rv.amount;
            if (open && rv.forged && _resolved(rv.client) && !h.leftOut(j + 1)) {
                assertTrue(booked, "a forged receive not booked");
            }
        }
        _checkFlows(f, tn, open);
        _checkPayments(n, tn);
        _checkCounters();
        // invariant 7: no loss changes while a reopening runs (the snapshot is taken when its kind 13 executes)
        if (ctl.routeReopening(clientId) && keccak256(bytes(h.snapshotClient())) == keccak256(bytes(h.liveClientId())))
        {
            for (uint256 t = 0; t < tn; t++) {
                assertEq(
                    ctl.losses(clientId, h.tokens(t)), h.lossSnapshot(h.tokens(t)), "losses changed while reopening"
                );
            }
            assertEq(
                ctl.losses(clientId, address(ugnot)),
                h.lossSnapshot(address(ugnot)),
                "voucher losses changed while reopening"
            );
        }
    }

    /// @notice Every refund paid since the last step left every other record's reservation backed, other refunds
    /// owed again included: the escrow covers the reservation of all records but the paid one (only it may stay
    /// short, by its own permitted shortfall). Independent of the aggregate checks, which a payment taking another
    /// refund's backing could leave unchanged.
    function _checkPayments(uint256 n, uint256 tn) internal view {
        address escrow = ics20.getEscrow(clientId);
        for (uint256 i = 0; i < n; i++) {
            IICS26RouterMsgs.Packet memory pkt = h.packet(i);
            T.SendRecord memory rec = ctl.sendRecord(pkt.sourceClient, pkt.sequence);
            if (rec.refunded <= h.refundedAt(i)) continue;
            // invariant 5: no kind 12 refund before every unsettled suspect success of the route is reserved
            if (rec.settlement == 1) assertTrue(h.allPrepared(), "a kind 12 refund before the preparation");
            if (_burnedOf(i)) continue;
            if (_tokenIndex(rec.token, tn) == tn) continue;
            uint256 own = _reserveOf(rec, i);
            assertGe(
                IERC20(rec.token).balanceOf(escrow) + own,
                ctl.reserved(clientId, rec.token),
                "a payment took another record's backing"
            );
        }
    }

    function _checkFlows(Flows memory f, uint256 tn, bool open) internal view {
        address escrow = ics20.getEscrow(clientId);
        for (uint256 t = 0; t < tn; t++) {
            address token = h.tokens(t);
            uint256 reserved = ctl.reserved(clientId, token);
            // the reservation equals the records' outstanding entitlements (no backing lost or invented)
            assertEq(reserved, f.reserve[t], "reservation equals the entitlements");
            // payment conservation, against the tokens themselves: what alice holds is what she started with, less
            // what she sent, plus what was refunded to her; the escrow holds what was sent, less every refund and
            // every receive; bob holds exactly what was received
            assertEq(
                IERC20(token).balanceOf(alice),
                h.initialAlice(token) - h.sentBy(alice, token) + f.refundedAlice[t],
                "alice's tokens"
            );
            uint256 sent =
                h.sentBy(alice, token) + h.sentBy(_adapter(), token) + h.sentBy(address(h.reentrant()), token);
            assertEq(
                IERC20(token).balanceOf(escrow), sent - f.refundedAll[t] - h.received(token), "the escrow's tokens"
            );
            assertEq(IERC20(token).balanceOf(bob), h.received(token), "bob's tokens");
            // and the escrow covers the reservation, but for the shortfall reconciliation recognized (the ghost's:
            // a forged success ack's hidden refund, owed again), which no receive or payment may increase
            // and only on the very refunds it belongs to, while unpaid: every other record's reservation is backed in
            // full (a payment of one refund never takes another's backing)
            uint256 bal = IERC20(token).balanceOf(escrow);
            uint256 allowed = h.permittedShortfall(token);
            if (f.eligibleUnpaid[t] < allowed) allowed = f.eligibleUnpaid[t];
            assertLe(reserved > bal ? reserved - bal : 0, allowed, "uncovered beyond the recognized loss");
            assertGe(bal, reserved - f.eligibleUnpaid[t], "another record's reservation lost its backing");
            // the booked losses equal the independently computed forged payouts
            assertEq(ctl.losses(clientId, token), f.loss[t], "losses equal the forged payouts");
            if (open) assertEq(ctl.acceptedDeficit(clientId, token), f.loss[t], "deficit accepted exactly");
        }
        // each contract sender holds what was minted to it, less what it sent, plus its own refunds; the adapter
        // less what it forwarded, which its owner holds, and nothing else
        SenderAdapter ad = SenderAdapter(_adapter());
        address re = address(h.reentrant());
        for (uint256 t = 0; t < tn; t++) {
            address token = h.tokens(t);
            uint256 fwd = token == address(ad.token()) ? ad.forwarded() : 0;
            assertEq(
                IERC20(token).balanceOf(re),
                h.minted(re, token) - h.sentBy(re, token) + f.refundedReentrant[t],
                "the re-entrant sender's tokens"
            );
            assertEq(
                IERC20(token).balanceOf(address(ad)),
                h.minted(address(ad), token) - h.sentBy(address(ad), token) + f.refundedAdapter[t] - fwd,
                "the adapter's tokens"
            );
            assertEq(IERC20(token).balanceOf(ad.owner()), fwd, "the adapter's owner's tokens: what it forwarded");
        }
        // the voucher: minted by receives and refunds, burned by bob's sends, all held by bob
        uint256 v = h.received(address(ugnot)) + f.refundedAll[tn] - h.sentBy(bob, address(ugnot));
        assertEq(ugnot.totalSupply(), h.ugnotSupply0() + v, "voucher supply");
        assertEq(ugnot.balanceOf(bob), v, "bob's vouchers");
        assertEq(ctl.losses(clientId, address(ugnot)), f.loss[tn], "voucher losses equal the forged mints");
        if (open) assertEq(ctl.acceptedDeficit(clientId, address(ugnot)), f.loss[tn], "voucher deficit exactly");
    }

    function _adapter() internal view returns (address) {
        return h.adapterAddress();
    }

    /// @notice A client id's counters against the work the ghost's transport history and incident boundaries call
    /// for, and resolved-incident completeness: an incident is resolved only once its client has no work left.
    /// Returns whether the client's incident is unresolved with work left (a pending incident). `retiredOnOpen`: a
    /// retired client on an open route, which must have none.
    function _checkClientWork(string memory c, uint64 resolved, bool retiredOnOpen) internal view returns (bool) {
        (uint64 open, uint32 incident,, uint64 suspect,) = ctl.clientRecon(c);
        if (retiredOnOpen) {
            assertEq(open, 0, "a retired client's record open on an open route");
            assertEq(suspect, 0, "a retired client's suspect record on an open route");
        }
        (uint64 o, uint64 sus) = h.expectedWork(c);
        assertEq(open, o, "open records (the ghost's)");
        assertEq(suspect, sus, "suspect records (the ghost's)");
        assertEq(incident != 0, h.retiredGhost(keccak256(bytes(c))), "retired exactly when a replacement retired it");
        if (incident != 0 && incident - 1 < resolved) {
            assertEq(o, 0, "a resolved incident's client with an open record");
            assertEq(sus, 0, "a resolved incident's client with a suspect record");
        }
        return incident != 0 && incident - 1 >= resolved && (open != 0 || suspect != 0);
    }

    function _checkCounters() internal view {
        (T.Incident[] memory inc, uint64 resolved, uint64 pending) = ctl.incidents(clientId);
        uint256 m = h.clientCount();
        bool closed = ctl.routeClosed(clientId);
        uint64 p;
        for (uint256 k = 0; k < m; k++) {
            if (_checkClientWork(h.clients(k), resolved, !closed && k + 1 < m)) p++;
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
        string[78] memory names = [
            "noticeResentAfterAck",
            "noticeResentOld",
            "preparePartial",
            "deliveredVoidHeld",
            "deliveredVoidHeldReversed",
            "noticeResent",
            "noticeAcked",
            "noticeTimedOut",
            "prepared",
            "proveAndPay",
            "voidReproveHeld",
            "twinInitialHeldSeparate",
            "tightenDelivery",
            "tightenDrain",
            "tightenInHookRefused",
            "tightenAfterHook",
            "retiredTimeout",
            "twinInitialHeld",
            "twinInitialHeldReversed",
            "twinRefundHeld",
            "replaceInDipRefunds",
            "replaceInDipRoute",
            "olderRefundHeld",
            "partialBackingHeld",
            "lossResolvedIncidentSealed",
            "continueNonTerminal",
            "prematureReopenRefused",
            "lateOnSettledIgnored",
            "provenAckReplaced",
            "approvalWithdrawn",
            "retiredAck",
            "abortObserved",
            "startReplacement",
            "executePending",
            "proveOne",
            "decideSettle",
            "startReopen",
            "sendVoucher",
            "adapterRefused",
            "settleExpiredRefused",
            "settleStaleGenRefused",
            "lossDuringReopeningRefused",
            "authoritySuspended",
            "abortInjected",
            "send",
            "sendFromAdapter",
            "relayHonest",
            "relayForged",
            "receiveHonest",
            "receiveForged",
            "receiveVoucher",
            "claim",
            "claimParked",
            "refundsFlag",
            "notify",
            "busyGovernance",
            "senderReentryRefused",
            "verifierFreeze",
            "verifierExpire",
            "verifierMigrate",
            "replace",
            "recover",
            "recoveryCancelled",
            "prove",
            "proveOnly",
            "proveCollision",
            "proveNonReceipt",
            "settle",
            "mismatchRefused",
            "settleStaleRefused",
            "replayRefused",
            "reconcile",
            "reopen",
            "continueReopen",
            "replaceDuringReopening",
            "lateLoss",
            "transportRound",
            "settle"
        ];
        string memory line = "ACTIONS";
        for (uint256 i = 0; i < names.length; i++) {
            line = string.concat(line, " ", names[i], "=", vm.toString(h.ok(names[i])));
        }
        console2.log(line);
        string[61] memory required = [
            "noticeResentAfterAck",
            "noticeResentOld",
            "preparePartial",
            "deliveredVoidHeld",
            "deliveredVoidHeldReversed",
            "noticeResent",
            "noticeAcked",
            "noticeTimedOut",
            "prepared",
            "proveAndPay",
            "voidReproveHeld",
            "twinInitialHeldSeparate",
            "tightenDelivery",
            "tightenDrain",
            "tightenInHookRefused",
            "tightenAfterHook",
            "retiredTimeout",
            "twinInitialHeld",
            "twinInitialHeldReversed",
            "twinRefundHeld",
            "replaceInDipRefunds",
            "replaceInDipRoute",
            "olderRefundHeld",
            "partialBackingHeld",
            "lossResolvedIncidentSealed",
            "continueNonTerminal",
            "prematureReopenRefused",
            "lateOnSettledIgnored",
            "provenAckReplaced",
            "approvalWithdrawn",
            "retiredAck",
            "startReplacement",
            "executePending",
            "proveOne",
            "decideSettle",
            "startReopen",
            "sendVoucher",
            "adapterRefused",
            "settleExpiredRefused",
            "settleStaleGenRefused",
            "lossDuringReopeningRefused",
            "authoritySuspended",
            "abortInjected",
            "reconcile",
            "reopen",
            "continueReopen",
            "replaceDuringReopening",
            "lateLoss",
            "transportRound",
            "relayHonest",
            "relayForged",
            "claimParked",
            "receiveForged",
            "receiveVoucher",
            "settle",
            "busyGovernance",
            "senderReentryRefused",
            "mismatchRefused",
            "settleStaleRefused",
            "replayRefused",
            "recoveryCancelled"
        ];
        for (uint256 i = 0; i < required.length; i++) {
            assertGe(h.ok(required[i]), 1, required[i]);
        }
    }
}
