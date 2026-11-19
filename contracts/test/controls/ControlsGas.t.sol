// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";

import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Gas of the controlled paths through the router (mock light client: proof verification excluded). Run with
/// `-vv` to see the numbers.
contract ControlsGasTest is ControlsFixture {
    function test_gas() public {
        _gnotIn(1e6, bob); // first receive creates the escrow
        _gnotIn(1e6, bob);
        console.log("recvPacket ugnot (steady state, limits + quarantine checked):", vm.lastCallGas().gasTotalUsed);

        _setLimits(address(usdc), 1e12, 1e12, 1e12);
        _send(alice, address(usdc), 1e6, clientId);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 1e6, clientId);
        console.log("sendTransfer usdc (escrow + send record):", vm.lastCallGas().gasTotalUsed);
        _errorAck(pkt);
        console.log("ackPacket error ack (refund paid at once):", vm.lastCallGas().gasTotalUsed);

        _recvGov(_env(1, S.KIND_SETTINGS, P.settings(clientId, 1 days)));
        console.log("recvPacket gov decision (recorded, pending):", vm.lastCallGas().gasTotalUsed);
        _skip(7 days);
        admin.execute(1);
        console.log("execute kind 11:", vm.lastCallGas().gasTotalUsed);
    }
}
