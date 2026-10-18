// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IGuardians } from "../../src/interfaces/IGuardians.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Byte-exact vectors of the governance channel (ADR pr6375 §5.4) for the gno.land side (`ibcgov`): for each
/// kind, its params, the full envelope and the app acknowledgement IBCAdmin writes for it, delivered in order through
/// the real router on a fresh deployment; plus the duplicate, conflict, buffered, spent and beyond-window-cancel
/// acknowledgements. `WRITE_GOV_VECTORS=true forge test --match-contract GovVectors` rewrites
/// test/fixtures/gov-vectors.json; otherwise the test checks every byte against it.
contract GovVectorsTest is ControlsFixture {
    string internal constant FILE = "test/fixtures/gov-vectors.json";

    struct Vector {
        string name;
        uint8 kind;
        uint64 seq;
        string params;
        bytes paramsHex;
        bytes envelope;
        bytes ack;
    }

    Vector[] internal vectors;

    function _deliver(string memory name, uint64 seq, uint8 kind, string memory desc, bytes memory params) internal {
        bytes memory envelope = _envelope(1, seq, kind, params);
        bytes memory ack = _recvGov(envelope);
        vectors.push(Vector(name, kind, seq, desc, params, envelope, ack));
    }

    function _prefix() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = "main";
        p[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
    }

    function _build() internal {
        _deliver(
            "kind2-unpause-route", 1, 2, "(uint8 object = 1, string clientId = \"client-0\")", P.unpause(1, "client-0")
        );
        IGuardians.SeatKey[] memory pairs = new IGuardians.SeatKey[](2);
        pairs[0] = IGuardians.SeatKey(0, 0x1111111111111111111111111111111111111111);
        pairs[1] = IGuardians.SeatKey(4, 0x2222222222222222222222222222222222222222);
        _deliver(
            "kind3-seats",
            2,
            3,
            "((uint8 seat, address key)[] = [(0, 0x1111111111111111111111111111111111111111), (4, 0x2222222222222222222222222222222222222222)])",
            P.seats(pairs)
        );
        _deliver(
            "kind4-limits",
            3,
            4,
            "(string clientId = \"client-0\", address token = 0x3333333333333333333333333333333333333333, uint256 maxPerMessage = 25000000000, uint256 dayCap = 100000000000, uint256 refundCap = 100000000000, uint256 sendMax = 0, uint256 sendMin = 0)",
            P.limits("client-0", 0x3333333333333333333333333333333333333333, 25_000e6, 100_000e6, 100_000e6, 0, 0)
        );
        _deliver(
            "kind5-voucher",
            4,
            5,
            "(string clientId = \"client-0\", string baseDenom = \"ufoo\", address voucher = 0x4444444444444444444444444444444444444444, bytes32 codeHash = 0xaa..aa)",
            P.voucher(
                "client-0", "ufoo", 0x4444444444444444444444444444444444444444, bytes32(type(uint256).max / 255 * 0xaa)
            )
        );
        _deliver(
            "kind6-client-add",
            5,
            6,
            "(uint8 op = 1, string clientId = \"gnoland-2\", string counterpartyClientId = \"ethereum-2\", bytes[] merklePrefix = [\"main\", \"/pv/vm:gno.land/r/aib/ibc/core:\"], address lightClient = 0x5555555555555555555555555555555555555555, bytes32 codeHash = 0xbb..bb)",
            P.client(
                1,
                "gnoland-2",
                "ethereum-2",
                _prefix(),
                0x5555555555555555555555555555555555555555,
                bytes32(type(uint256).max / 255 * 0xbb)
            )
        );
        _deliver(
            "kind7-upgrade",
            6,
            7,
            "(address proxy = 0x6666666666666666666666666666666666666666, address implementation = 0x7777777777777777777777777777777777777777, bytes32 codeHash = 0xcc..cc, bytes call = 0x)",
            P.upgrade(
                0x6666666666666666666666666666666666666666,
                0x7777777777777777777777777777777777777777,
                bytes32(type(uint256).max / 255 * 0xcc),
                ""
            )
        );
        _deliver(
            "kind8-role-grant-relayer",
            7,
            8,
            "(bool grant = true, uint64 roleId = 1, address account = 0x8888888888888888888888888888888888888888)",
            P.role(true, 1, 0x8888888888888888888888888888888888888888)
        );
        _deliver(
            "kind9-handover",
            8,
            9,
            "(address exec = 0x9999999999999999999999999999999999999999, bytes32 codeHash = 0xdd..dd, bytes migrationCall = 0x)",
            P.handover(0x9999999999999999999999999999999999999999, bytes32(type(uint256).max / 255 * 0xdd), "")
        );
        _deliver(
            "kind10-route",
            9,
            10,
            "(string oldClientId = \"client-0\", string newClientId = \"gnoland-2\", uint64 suspectFrom = 21000000)",
            P.route("client-0", "gnoland-2", 21_000_000)
        );
        _deliver(
            "kind11-settings-lengthen",
            10,
            11,
            "(string clientId = \"client-0\", uint64 quarantineSeconds = 1209600) - a lengthening, executed at recording",
            P.settings("client-0", 14 days)
        );
        P.Range[] memory ranges = new P.Range[](1);
        ranges[0] = P.Range(2, 3);
        _deliver("kind1-cancel", 11, 1, "((uint64 from, uint64 to)[] ranges = [(2, 3)])", P.cancel(ranges));
        // a duplicate and a conflict of seq 1, a buffered seq 13, a spent unknown kind at seq 12 (which drains 13), and
        // a cancel beyond the window (tombstones applied, success ack with redispatch = 1)
        _deliver("duplicate-of-seq-1", 1, 2, "the bytes of kind2-unpause-route again", P.unpause(1, "client-0"));
        _deliver(
            "conflict-at-seq-1",
            1,
            2,
            "(uint8 object = 2, string clientId = \"\") at seq 1: other bytes",
            P.unpause(2, "")
        );
        _deliver(
            "buffered-seq-13",
            13,
            11,
            "(string clientId = \"client-0\", uint64 quarantineSeconds = 86400)",
            P.settings("client-0", 1 days)
        );
        _deliver("spent-unknown-kind", 12, 99, "kind 99, no params", "");
        P.Range[] memory far = new P.Range[](1);
        far[0] = P.Range(100, 120);
        _deliver(
            "cancel-beyond-window",
            200,
            1,
            "((uint64 from, uint64 to)[] ranges = [(100, 120)]) at seq 200",
            P.cancel(far)
        );
        P.SettleItem[] memory items = new P.SettleItem[](2);
        items[0] = P.SettleItem(1, 1, 100);
        items[1] = P.SettleItem(2, 2, 0);
        _deliver(
            "kind12-settle",
            14,
            12,
            "(string clientId = \"client-0\", (uint64 sequence, uint8 action, uint256 amount)[] items = [(1, 1, 100), (2, 2, 0)])",
            P.settle("client-0", items)
        );
        _deliver("kind13-reopen", 15, 13, "(string clientId = \"gnoland-2\")", P.reopen("gnoland-2"));
        _deliver(
            "kind12-settle-zero",
            16,
            12,
            "(string clientId = \"client-0\", (uint64 sequence, uint8 action, uint256 amount)[] items = [(3, 1, 0)]) - a genuine refund already paid in full",
            P.settle1("client-0", 3, 1, 0)
        );
        _deliver(
            "kind12-settle-forged-receive",
            17,
            12,
            "(string clientId = \"client-0\", (uint64 sequence, uint8 action, uint256 amount)[] items = [(7, 5, 100000000)]) - action 5: a forged receive at inbound sequence 7 that released 100000000",
            P.settle1("client-0", 7, 5, 100_000_000)
        );
    }

    function _json() internal view returns (string memory j) {
        j = string.concat(
            "{\n  \"description\": \"ADR pr6375 section 5.4 governance channel vectors, generated by contracts/test/controls/GovVectors.t.sol. ",
            "Each vector was delivered in order, through the real ICS26Router, to a fresh IBCAdmin at epoch 1; ack is what IBCAdmin wrote.\",\n",
            "  \"payload\": {\"sourcePort\": \"gov\", \"destPort\": \"ibcgov\", \"version\": \"ibcgov-1\", \"encoding\": \"application/x-ibcgov\"},\n",
            "  \"envelope\": \"version u8 (1) | epoch u32 BE | seq u64 BE | kind u8 | params; params = abi.encode(field1, field2, ...) of the kind's tuple; at most 1024 bytes\",\n",
            "  \"ack\": \"epoch u32 BE | seq u64 BE | status u8 (1 recorded, 2 buffered, 3 duplicate, 4 conflict, 5 spent) | redispatch u8\",\n",
            "  \"vectors\": [\n"
        );
        for (uint256 i = 0; i < vectors.length; i++) {
            Vector memory v = vectors[i];
            (,, uint8 status, uint8 redispatch) = _govAck(v.ack);
            j = string.concat(
                j,
                "    {\"name\": \"",
                v.name,
                "\", \"kind\": ",
                vm.toString(v.kind),
                ", \"epoch\": 1, \"seq\": ",
                vm.toString(v.seq),
                ", \"params\": \"",
                _escape(v.params),
                "\", \"paramsHex\": \"",
                vm.toString(v.paramsHex),
                "\", \"envelope\": \"",
                vm.toString(v.envelope),
                "\", \"ack\": \"",
                vm.toString(v.ack),
                "\", \"status\": ",
                vm.toString(status),
                ", \"redispatch\": ",
                vm.toString(redispatch),
                i + 1 == vectors.length ? "}\n" : "},\n"
            );
        }
        j = string.concat(j, "  ],\n", _noticeJson(), "}\n");
    }

    // ----------------------------------------------------------------------------------------- epoch notice --

    /// @notice The epoch notice IBCAdmin sends when a kind 10 (or the emergency recovery) opens epoch 2 over client
    /// `gnoland-2`, and gno.land's two acknowledgements that end it (status 1 switched, 3 already switched).
    function _notice() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), uint32(2), "gnoland-2");
    }

    function _noticeAck(uint8 status) internal pure returns (bytes memory) {
        return abi.encodePacked(uint32(2), uint64(0), status, uint8(0));
    }

    function _noticeJson() internal pure returns (string memory) {
        return string.concat(
            "  \"epochNotice\": {\"description\": \"Sent by IBCAdmin from port ibcgov over the NEW client (the packet's ",
            "source client, here gnoland-2) to gno.land's gov port when a kind 10 or the emergency recovery opens the next ",
            "epoch; timeout 23 hours. Anyone re-sends it, with the same bytes in a fresh packet over that epoch's client, ",
            "by resendEpochNotice(epoch) at any time, before or after an acknowledgement: an acknowledgement is ",
            "informational and never closes resending. notice = version u8 (1) | epoch u32 BE | clientId (raw trailing ",
            "bytes, no length); ack = epoch u32 BE | seq u64 (0) | status u8 | redispatch u8 (0); status 1 (switched) or 3 ",
            "(already switched) marks it acknowledged, and nothing clears the mark; any other answer (eureka's universal ",
            "error ack) or a timeout does not.\", ",
            "\"payload\": {\"sourcePort\": \"ibcgov\", \"destPort\": \"gov\", \"version\": \"ibcgov-1\", ",
            "\"encoding\": \"application/x-ibcgov\"}, \"epoch\": 2, \"clientId\": \"gnoland-2\", ",
            "\"timeoutSeconds\": 82800, \"notice\": \"",
            vm.toString(_notice()),
            "\", \"ackSwitched\": \"",
            vm.toString(_noticeAck(1)),
            "\", \"ackDuplicate\": \"",
            vm.toString(_noticeAck(3)),
            "\"}\n"
        );
    }

    /// @notice The vector is what IBCAdmin sends: a kind 10 to `gnoland-2` executed through the real router, its
    /// notice's bytes and payload checked against the file, and both acks end it.
    function test_epochNoticeVector() public {
        MockLightClient c = new MockLightClient();
        _recvGov(
            _env(1, S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(c), address(c).codehash))
        );
        _recvGov(_env(2, S.KIND_ROUTE, P.route(clientId, "gnoland-2")));
        _skip(7 days);
        admin.execute(1);
        vm.recordLogs();
        admin.execute(2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IICS26RouterMsgs.Packet memory pkt;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.SendPacket.selector) {
                pkt = abi.decode(logs[i].data, (IICS26RouterMsgs.Packet));
            }
        }
        assertEq(pkt.payloads[0].value, _notice());
        assertEq(pkt.timeoutTimestamp, _now() + 82_800);
        if (!vm.envOr("WRITE_GOV_VECTORS", false)) {
            string memory file = vm.readFile(FILE);
            assertEq(vm.parseJsonBytes(file, ".epochNotice.notice"), _notice());
            assertEq(vm.parseJsonBytes(file, ".epochNotice.ackSwitched"), _noticeAck(1));
            assertEq(vm.parseJsonBytes(file, ".epochNotice.ackDuplicate"), _noticeAck(3));
        }
        router.ackPacket(IICS26RouterMsgs.MsgAckPacket(pkt, _noticeAck(1), "", IICS02ClientMsgs.Height(0, 1)));
        assertTrue(admin.epochNoticeAcked(2));
    }

    function _escape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length * 2);
        uint256 n;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "\"" || b[i] == "\\") out[n++] = "\\";
            out[n++] = b[i];
        }
        assembly {
            mstore(out, n)
        }
        return string(out);
    }

    function test_govVectors() public {
        _build();
        // the statuses the protocol must produce
        uint8[20] memory want = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 4, 2, 5, 2, 1, 1, 1, 1];
        for (uint256 i = 0; i < vectors.length; i++) {
            (uint32 e, uint64 s, uint8 st,) = _govAck(vectors[i].ack);
            assertEq(e, 1);
            assertEq(s, vectors[i].seq);
            assertEq(st, want[i], vectors[i].name);
        }
        (,,, uint8 redispatch) = _govAck(vectors[15].ack);
        assertEq(redispatch, 1);
        assertEq(admin.lastSeq(), 17);

        if (vm.envOr("WRITE_GOV_VECTORS", false)) {
            vm.writeFile(FILE, _json());
            return;
        }
        string memory file = vm.readFile(FILE);
        for (uint256 i = 0; i < vectors.length; i++) {
            string memory at = string.concat(".vectors[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(file, string.concat(at, ".name")), vectors[i].name);
            assertEq(vm.parseJsonBytes(file, string.concat(at, ".envelope")), vectors[i].envelope, vectors[i].name);
            assertEq(vm.parseJsonBytes(file, string.concat(at, ".ack")), vectors[i].ack, vectors[i].name);
            assertEq(vm.parseJsonBytes(file, string.concat(at, ".paramsHex")), vectors[i].paramsHex, vectors[i].name);
        }
    }
}
