// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { AccessManager } from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Mock } from "@openzeppelin-contracts/mocks/token/ERC20Mock.sol";
import { IAccessManaged } from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";

import { ICS26Router } from "@eureka/ICS26Router.sol";
import { ICS20Transfer } from "@eureka/ICS20Transfer.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { Escrow } from "@eureka/utils/Escrow.sol";
import { IBCERC20 } from "@eureka/utils/IBCERC20.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";

import { GnoICS20Transfer } from "../../src/GnoICS20Transfer.sol";
import { GnoVoucher } from "../../src/GnoVoucher.sol";
import { GnoICS20Controls } from "../../src/transfer/GnoICS20Controls.sol";
import { IGnoICS20Controls, IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";

/// @notice The fork's storage is append-only to eureka's ICS20Transfer: a proxy that ran the stock implementation
/// keeps its escrows, registry, beacons and bindings through the UUPS upgrade, and a packet sent before it is still
/// acknowledged and refunded (its send record made by the callback).
contract UpgradeCompatTest is Test {
    AccessManager internal am;
    ICS26Router internal router;
    address internal ics20;
    MockLightClient internal lc;
    GnoVoucher internal ugnot;
    ERC20Mock internal usdc;
    string internal clientId;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_700_000_000);
        am = new AccessManager(address(this));
        router = ICS26Router(
            address(new ERC1967Proxy(address(new ICS26Router()), abi.encodeCall(ICS26Router.initialize, (address(am)))))
        );
        ics20 = address(
            new ERC1967Proxy(
                address(new ICS20Transfer()),
                abi.encodeCall(
                    ICS20Transfer.initialize,
                    (address(router), address(new Escrow()), address(new IBCERC20()), address(0), address(am))
                )
            )
        );
        am.setTargetFunctionRole(address(router), IBCRolesLib.ics26RelayerSelectors(), IBCRolesLib.PUBLIC_ROLE);
        router.addIBCApp(ICS20Lib.DEFAULT_PORT_ID, ics20);
        lc = new MockLightClient();
        bytes[] memory prefix = new bytes[](1);
        prefix[0] = "";
        clientId = router.addClient(IICS02ClientMsgs.CounterpartyInfo("ethereum-1", prefix), address(lc));
        ugnot = new GnoVoucher("Gno.land", "GNOT", 6, ics20, "transfer/client-0/ugnot");
        ICS20Transfer(ics20).setCustomERC20("transfer/client-0/ugnot", address(ugnot));
        usdc = new ERC20Mock();
        usdc.mint(alice, 1000);
        vm.prank(alice);
        usdc.approve(ics20, type(uint256).max);
    }

    function _sendUsdc(uint256 amount) internal returns (IICS26RouterMsgs.Packet memory) {
        vm.recordLogs();
        vm.prank(alice);
        ICS20Transfer(ics20)
            .sendTransfer(
                IICS20TransferMsgs.SendTransferMsg({
                denom: address(usdc),
                amount: amount,
                receiver: "g1receiver",
                sourceClient: clientId,
                destPort: ICS20Lib.DEFAULT_PORT_ID,
                timeoutTimestamp: uint64(vm.getBlockTimestamp() + 600),
                memo: ""
            })
            );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IICS26Router.SendPacket.selector) {
                return abi.decode(logs[i].data, (IICS26RouterMsgs.Packet));
            }
        }
        revert("no packet");
    }

    function test_upgradeKeepsUpstreamState_andLegacyPacketsRefund() public {
        IICS26RouterMsgs.Packet memory legacy = _sendUsdc(400);
        address escrow = ICS20Transfer(ics20).getEscrow(clientId);
        address escrowBeacon = ICS20Transfer(ics20).getEscrowBeacon();
        address ibcBeacon = ICS20Transfer(ics20).getIBCERC20Beacon();
        assertEq(usdc.balanceOf(escrow), 400);

        address controls = address(new GnoICS20Controls());
        address fork = address(new GnoICS20Transfer(controls));
        address[6] memory keys = [address(1), address(2), address(3), address(4), address(5), address(6)];
        UUPSUpgradeable(ics20).upgradeToAndCall(fork, abi.encodeCall(IGnoICS20Controls.initializeGno, (keys)));

        // upstream's namespace is untouched
        assertEq(ICS20Transfer(ics20).getEscrow(clientId), escrow);
        assertEq(ICS20Transfer(ics20).getEscrowBeacon(), escrowBeacon);
        assertEq(ICS20Transfer(ics20).getIBCERC20Beacon(), ibcBeacon);
        assertEq(ICS20Transfer(ics20).ics26(), address(router));
        assertEq(IAccessManaged(ics20).authority(), address(am));
        assertEq(ICS20Transfer(ics20).ibcERC20Contract("transfer/client-0/ugnot"), address(ugnot));
        assertEq(ICS20Transfer(ics20).ibcERC20Denom(address(ugnot)), "transfer/client-0/ugnot");
        assertEq(IGnoICS20Controls(ics20).guardianKeys()[3], address(4));
        // initialized once
        vm.expectRevert();
        IGnoICS20Controls(ics20).initializeGno(keys);

        // the packet sent before the upgrade: no limits yet, so its refund is queued, with a record made for it
        router.ackPacket(
            IICS26RouterMsgs.MsgAckPacket(legacy, ICS24Host.UNIVERSAL_ERROR_ACK, "", IICS02ClientMsgs.Height(0, 1))
        );
        T.SendRecord memory rec = IGnoICS20Controls(ics20).sendRecord(clientId, legacy.sequence);
        assertEq(rec.commitment, bytes32(0));
        assertEq(rec.sendBlock, 0);
        assertEq(rec.amount, 400);
        assertEq(rec.sender, alice);
        assertEq(uint8(rec.payment), uint8(T.Payment.Queued));
        assertEq(usdc.balanceOf(alice), 600);

        IGnoICS20Controls(ics20).setLimits(clientId, address(usdc), T.Limits(0, 0, 1000, 0, 0));
        assertEq(IGnoICS20Controls(ics20).claim(clientId, address(usdc), 5), 1);
        assertEq(usdc.balanceOf(alice), 1000);
    }
}
