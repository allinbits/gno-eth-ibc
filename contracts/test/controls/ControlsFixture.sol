// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { ERC20Mock } from "@openzeppelin-contracts/mocks/token/ERC20Mock.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";

import { ICS26Router } from "@eureka/ICS26Router.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";
import { IIBCSenderCallbacks } from "@eureka/interfaces/IIBCSenderCallbacks.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { DeployGnoIBC } from "../../script/DeployGnoIBC.s.sol";
import { GnoICS20Transfer } from "../../src/GnoICS20Transfer.sol";
import { GnoVoucher } from "../../src/GnoVoucher.sol";
import { IGnoICS20Controls, IGnoICS20ControlsTypes } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdmin } from "../../src/admin/IBCAdmin.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";

/// @notice The whole Ethereum side as DeployGnoIBC deploys it (AccessManager, ICS26Router, the ICS20 proxy upgraded
/// to GnoICS20Transfer, IBCAdmin on `gov`, every authority handed over and checked), over a MockLightClient, with
/// helpers that drive the real router: packets from gno.land, sends, acknowledgements, timeouts, governance packets.
abstract contract ControlsFixture is Test, DeployGnoIBC {
    string internal constant CP = "ethereum-1";
    string internal constant GNO_SENDER = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5";
    uint256 internal constant GNOT_MAX = 25_000e6;
    uint256 internal constant GNOT_DAY = 100_000e6;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address[4] internal G;
    address[2] internal W;

    MockLightClient internal lc;
    Deployed internal d;
    ICS26Router internal router;
    IGnoICS20Controls internal ctl;
    GnoICS20Transfer internal ics20;
    IBCAdmin internal admin;
    GnoVoucher internal ugnot;
    ERC20Mock internal usdc;
    string internal clientId;

    mapping(bytes32 destClient => uint64) internal nextRecvSeq;

    /// @notice What the deployment created, as it passed it to `finishSetup`.
    IIBCAdmin.Launch internal launch;

    function _recovery() internal virtual returns (IIBCAdmin.RecoveryConfig memory c) { }

    function _permit2() internal virtual returns (address) { }

    /// @notice The ugnot limits the deployment installs (the suites run an active route; `InactiveLaunchTest` the
    /// production launch, zero).
    function _gnotLimits() internal virtual returns (IGnoICS20ControlsTypes.Limits memory) {
        return IGnoICS20ControlsTypes.Limits(GNOT_MAX, GNOT_DAY, GNOT_DAY, 0, 0);
    }

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        vm.roll(1000);
        for (uint256 i = 0; i < 4; i++) {
            G[i] = makeAddr(string.concat("guardian", vm.toString(i)));
        }
        W = [makeAddr("watch0"), makeAddr("watch1")];
        lc = new MockLightClient();
        Params memory p;
        p.deployer = deployer;
        p.lightClient = address(lc);
        p.counterparty = CP;
        p.guardians = G;
        p.watch = W;
        p.clientState.chainId = "gno-test";
        p.expectedLock = 1_000_000e6;
        p.gnotLimits = _gnotLimits();
        p.permit2 = _permit2();
        p.quarantineSeconds = 7 days;
        p.recovery = _recovery();
        vm.startPrank(deployer);
        d = _deploy(p);
        vm.stopPrank();
        launch = _launch(p, d);
        router = ICS26Router(d.ics26Router);
        ctl = IGnoICS20Controls(d.ics20Transfer);
        ics20 = GnoICS20Transfer(d.ics20Transfer);
        admin = IBCAdmin(d.ibcAdmin);
        ugnot = GnoVoucher(d.ugnotVoucher);
        clientId = d.clientId;
        usdc = new ERC20Mock();
        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(d.ics20Transfer, type(uint256).max);
    }

    // ------------------------------------------------------------------------------------------------ time --

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _skip(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 1 + dt / 12);
    }

    // ------------------------------------------------------------------------------------------- governance --

    /// @notice Governance by IBCAdmin directly (it holds ADMIN_ROLE), for unit tests of the transfer controls.
    function _setLimits(address token, uint256 maxPerMessage, uint256 dayCap, uint256 refundCap) internal {
        _setLimits(clientId, token, IGnoICS20ControlsTypes.Limits(maxPerMessage, dayCap, refundCap, 0, 0));
    }

    function _setLimits(string memory id, address token, IGnoICS20ControlsTypes.Limits memory l) internal {
        vm.prank(address(admin));
        ctl.setLimits(id, token, l);
    }

    // ------------------------------------------------------------------------------------------- packets in --

    function _packetFromGno(
        string memory destClient,
        string memory port,
        string memory version,
        string memory encoding,
        bytes memory value
    )
        internal
        returns (IICS26RouterMsgs.Packet memory pkt)
    {
        IICS26RouterMsgs.Payload[] memory pl = new IICS26RouterMsgs.Payload[](1);
        pl[0] = IICS26RouterMsgs.Payload(port, port, version, encoding, value);
        string memory source = router.getCounterparty(destClient).clientId;
        pkt = IICS26RouterMsgs.Packet({
            sequence: ++nextRecvSeq[keccak256(bytes(destClient))],
            sourceClient: source,
            destClient: destClient,
            timeoutTimestamp: uint64(_now() + 1 hours),
            payloads: pl
        });
    }

    /// @notice Delivers a packet through the router and returns the acknowledgement it wrote.
    function _recv(IICS26RouterMsgs.Packet memory pkt) internal returns (bytes memory ack) {
        vm.recordLogs();
        router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(pkt, "", IICS02ClientMsgs.Height(0, 1)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.WriteAcknowledgement.selector) {
                (, bytes[] memory acks) = abi.decode(logs[i].data, (IICS26RouterMsgs.Packet, bytes[]));
                return acks[0];
            }
        }
        revert("no acknowledgement written");
    }

    function _isErrorAck(bytes memory ack) internal pure returns (bool) {
        return keccak256(ack) == ICS24Host.KECCAK256_UNIVERSAL_ERROR_ACK;
    }

    function _isSuccessAck(bytes memory ack) internal pure returns (bool) {
        return keccak256(ack) == keccak256(ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON);
    }

    /// @notice A token transfer from gno.land to `receiver` over `destClient`.
    function _transferIn(
        string memory destClient,
        string memory denom,
        uint256 amount,
        address receiver
    )
        internal
        returns (bytes memory ack)
    {
        IICS20TransferMsgs.FungibleTokenPacketData memory data = IICS20TransferMsgs.FungibleTokenPacketData({
            denom: denom, sender: GNO_SENDER, receiver: Strings.toHexString(receiver), amount: amount, memo: ""
        });
        return _recv(
            _packetFromGno(
                destClient, ICS20Lib.DEFAULT_PORT_ID, ICS20Lib.ICS20_VERSION, ICS20Lib.ICS20_ENCODING, abi.encode(data)
            )
        );
    }

    function _gnotIn(uint256 amount, address receiver) internal returns (bytes memory) {
        return _transferIn(clientId, "ugnot", amount, receiver);
    }

    // ------------------------------------------------------------------------------------------ packets out --

    /// @notice `from` sends `amount` of `token` to gno.land over `sourceClient`; returns the packet the router
    /// committed.
    function _send(
        address from,
        address token,
        uint256 amount,
        string memory sourceClient
    )
        internal
        returns (IICS26RouterMsgs.Packet memory pkt)
    {
        vm.recordLogs();
        vm.prank(from);
        ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg({
                denom: token,
                amount: amount,
                receiver: GNO_SENDER,
                sourceClient: sourceClient,
                destPort: ICS20Lib.DEFAULT_PORT_ID,
                timeoutTimestamp: uint64(_now() + 1 hours),
                memo: ""
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.SendPacket.selector) {
                return abi.decode(logs[i].data, (IICS26RouterMsgs.Packet));
            }
        }
        revert("no packet sent");
    }

    /// @notice A send expected to revert (no packet to return).
    function _sendExpectRevert(
        address from,
        address token,
        uint256 amount,
        string memory sourceClient,
        bytes memory err
    )
        internal
    {
        vm.expectRevert(err);
        vm.prank(from);
        ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg({
                denom: token,
                amount: amount,
                receiver: GNO_SENDER,
                sourceClient: sourceClient,
                destPort: ICS20Lib.DEFAULT_PORT_ID,
                timeoutTimestamp: uint64(_now() + 1 hours),
                memo: ""
            })
        );
    }

    /// @notice The notification the router's error ack carried to the sender (this test is the relayer).
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

    /// @notice The notification the router's timeout carried to the sender (this test is the relayer).
    function _timeoutNotice(IICS26RouterMsgs.Packet memory pkt) internal view returns (bytes memory) {
        return abi.encodeCall(
            IIBCSenderCallbacks.onTimeoutPacket,
            (IIBCAppCallbacks.OnTimeoutPacketCallback(
                    pkt.sourceClient, pkt.destClient, pkt.sequence, pkt.payloads[0], address(this)
                ))
        );
    }

    /// @notice Proves a packet's destination outcome through its route's replacement client (a permissive mock in
    /// these tests): its own receipt and `ack`.
    function _prove(IICS26RouterMsgs.Packet memory pkt, bytes memory ack) internal {
        ctl.proveOutcome(
            pkt, IGnoICS20ControlsTypes.OutcomeProof(IICS02ClientMsgs.Height(0, 1), ctl.gnoReceipt(pkt), "", ack, "")
        );
    }

    /// @notice Proven refundable: received with an error ack.
    function _proveRefundable(IICS26RouterMsgs.Packet memory pkt) internal {
        _prove(pkt, ICS24Host.UNIVERSAL_ERROR_ACK);
    }

    /// @notice Proven delivered: received with a success ack.
    function _proveDelivered(IICS26RouterMsgs.Packet memory pkt) internal {
        _prove(pkt, bytes("{\"result\":\"AQ==\"}"));
    }

    function _ack(IICS26RouterMsgs.Packet memory pkt, bytes memory ack) internal {
        router.ackPacket(IICS26RouterMsgs.MsgAckPacket(pkt, ack, "", IICS02ClientMsgs.Height(0, 1)));
    }

    function _errorAck(IICS26RouterMsgs.Packet memory pkt) internal {
        _ack(pkt, ICS24Host.UNIVERSAL_ERROR_ACK);
    }

    function _timeout(IICS26RouterMsgs.Packet memory pkt) internal {
        lc.setTimestamp(pkt.timeoutTimestamp);
        router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(pkt, "", IICS02ClientMsgs.Height(0, 1)));
        lc.setTimestamp(0);
    }

    // ---------------------------------------------------------------------------------- governance packets --

    function _envelope(uint32 epoch, uint64 seq, uint8 kind, bytes memory params) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), epoch, seq, kind, params);
    }

    function _env(uint64 seq, uint8 kind, bytes memory params) internal view returns (bytes memory) {
        return _envelope(admin.epoch(), seq, kind, params);
    }

    function _govPacket(bytes memory envelope) internal returns (IICS26RouterMsgs.Packet memory pkt) {
        pkt = _packetFromGno(admin.govClient(), "ibcgov", "ibcgov-1", "application/x-ibcgov", envelope);
        pkt.payloads[0].sourcePort = "gov";
    }

    function _recvGov(bytes memory envelope) internal returns (bytes memory) {
        return _recv(_govPacket(envelope));
    }

    function _govAck(bytes memory ack)
        internal
        pure
        returns (uint32 epoch, uint64 seq, uint8 status, uint8 redispatch)
    {
        require(ack.length == 14, "gov ack length");
        assembly {
            let w := mload(add(ack, 32))
            epoch := shr(224, w)
            seq := and(shr(160, w), 0xffffffffffffffff)
            status := and(shr(152, w), 0xff)
            redispatch := and(shr(144, w), 0xff)
        }
    }

    function _status(bytes memory ack) internal pure returns (uint8 status) {
        (,, status,) = _govAck(ack);
    }
}
