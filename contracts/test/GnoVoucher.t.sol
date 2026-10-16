// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ICS20Transfer } from "@eureka/ICS20Transfer.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";

import { GnoVoucher } from "../src/GnoVoucher.sol";
import { IGnoICS20ControlsTypes } from "../src/interfaces/IGnoICS20Controls.sol";
import { IGnoLightClientMsgs as Msgs } from "../src/msgs/IGnoLightClientMsgs.sol";
import { DeployGnoIBC } from "../script/DeployGnoIBC.s.sol";
import { Fixtures } from "./utils/Fixtures.sol";

/// @notice Exposes DeployGnoIBC's deployment, run with this contract as the deployer.
contract DeployHarness is DeployGnoIBC {
    function deploy(Msgs.ClientState memory cs, Msgs.ConsensusState memory cons) external returns (Deployed memory) {
        Params memory p;
        p.deployer = address(this);
        p.clientState = cs;
        p.consensusState = cons;
        p.counterparty = "ethereum-1";
        p.guardians = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
        p.watch = [address(0x1005), address(0x1006)];
        p.gnotLimits = IGnoICS20ControlsTypes.Limits(25_000e6, 100_000e6, 100_000e6, 0, 0);
        p.quarantineSeconds = 7 days;
        return _deploy(p);
    }
}

contract GnoVoucherTest is Fixtures {
    string internal constant UGNOT = "transfer/client-0/ugnot";
    address internal constant RECEIVER = address(0xBEEF);
    string internal constant GNO_ADDRESS = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5";

    DeployGnoIBC.Deployed internal d;
    ICS20Transfer internal ics20;

    function setUp() public {
        _loadFixtures();
        vm.warp(t0Seconds + 120);
        d = new DeployHarness().deploy(_initialClientState(), _initialConsensusState());
        ics20 = ICS20Transfer(d.ics20Transfer);
    }

    function _recv(string memory denom, uint256 amount) internal {
        bytes memory data = abi.encode(
            IICS20TransferMsgs.FungibleTokenPacketData({
                denom: denom, sender: GNO_ADDRESS, receiver: vm.toString(RECEIVER), amount: amount, memo: ""
            })
        );
        vm.prank(d.ics26Router);
        bytes memory ack = ics20.onRecvPacket(
            IIBCAppCallbacks.OnRecvPacketCallback({
                sourceClient: "ethereum-1",
                destinationClient: d.clientId,
                sequence: 1,
                payload: IICS26RouterMsgs.Payload({
                    sourcePort: ICS20Lib.DEFAULT_PORT_ID,
                    destPort: ICS20Lib.DEFAULT_PORT_ID,
                    version: ICS20Lib.ICS20_VERSION,
                    encoding: ICS20Lib.ICS20_ENCODING,
                    value: data
                }),
                relayer: address(this)
            })
        );
        assertEq(ack, ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON);
    }

    function test_ugnotVoucherIsRegisteredAtDeploy() public view {
        assertEq(d.clientId, "client-0");
        assertEq(ics20.ibcERC20Contract(UGNOT), d.ugnotVoucher);
        assertEq(ics20.ibcERC20Denom(d.ugnotVoucher), UGNOT);
        IERC20Metadata v = IERC20Metadata(d.ugnotVoucher);
        assertEq(v.decimals(), 6);
        assertEq(v.symbol(), "GNOT");
        assertEq(v.name(), "Gno.land");
        assertEq(GnoVoucher(d.ugnotVoucher).fullDenomPath(), UGNOT);
    }

    function test_receivingUgnotMintsTheVoucher() public {
        _recv("ugnot", 1_500_000); // 1.5 GNOT
        IERC20Metadata v = IERC20Metadata(d.ugnotVoucher);
        assertEq(v.balanceOf(RECEIVER), 1_500_000);
        assertEq(v.totalSupply(), 1_500_000);
        assertEq(v.balanceOf(RECEIVER) / 10 ** v.decimals(), 1);
    }

    function test_sendingUgnotBackBurnsTheVoucher() public {
        _recv("ugnot", 1_500_000);
        vm.startPrank(RECEIVER);
        IERC20Metadata(d.ugnotVoucher).approve(d.ics20Transfer, 1_000_000);
        ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg({
                denom: d.ugnotVoucher,
                amount: 1_000_000,
                receiver: GNO_ADDRESS,
                sourceClient: d.clientId,
                destPort: ICS20Lib.DEFAULT_PORT_ID,
                timeoutTimestamp: uint64(block.timestamp + 600),
                memo: ""
            })
        );
        vm.stopPrank();
        assertEq(IERC20Metadata(d.ugnotVoucher).balanceOf(RECEIVER), 500_000);
        assertEq(IERC20Metadata(d.ugnotVoucher).totalSupply(), 500_000);
    }

    /// @notice Default deny (ADR E6): a gno.land denom without a registered voucher is refused, so no stock
    /// 18-decimal IBCERC20 is ever created for it.
    function test_otherDenomsAreRefused() public {
        bytes memory data = abi.encode(
            IICS20TransferMsgs.FungibleTokenPacketData({
                denom: "gno.land/r/demo/foo", sender: GNO_ADDRESS, receiver: vm.toString(RECEIVER), amount: 7, memo: ""
            })
        );
        vm.prank(d.ics26Router);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGnoICS20ControlsTypes.GnoDenomNotRegistered.selector, "transfer/client-0/gno.land/r/demo/foo"
            )
        );
        ics20.onRecvPacket(
            IIBCAppCallbacks.OnRecvPacketCallback({
                sourceClient: "ethereum-1",
                destinationClient: d.clientId,
                sequence: 1,
                payload: IICS26RouterMsgs.Payload({
                    sourcePort: ICS20Lib.DEFAULT_PORT_ID,
                    destPort: ICS20Lib.DEFAULT_PORT_ID,
                    version: ICS20Lib.ICS20_VERSION,
                    encoding: ICS20Lib.ICS20_ENCODING,
                    value: data
                }),
                relayer: address(this)
            })
        );
    }

    function test_onlyICS20MintsAndBurns() public {
        GnoVoucher v = GnoVoucher(d.ugnotVoucher);
        vm.expectRevert(abi.encodeWithSelector(GnoVoucher.GnoVoucherUnauthorized.selector, address(this)));
        v.mint(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(GnoVoucher.GnoVoucherUnauthorized.selector, address(this)));
        v.burn(address(this), 1);
    }

    function test_registeringATakenDenomReverts() public {
        vm.expectRevert();
        ics20.setCustomERC20(UGNOT, address(1));
    }
}
