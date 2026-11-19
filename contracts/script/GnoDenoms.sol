// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICS20Transfer } from "@eureka/ICS20Transfer.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { GnoVoucher } from "../src/GnoVoucher.sol";

library GnoDenoms {
    /// @notice Deploys the voucher of a gno.land denom arriving over clientId.
    /// @param denom the denom on gno.land, e.g. "ugnot"
    /// @param decimals the denom's decimals on gno.land
    function deploy(
        address ics20Transfer,
        string memory clientId,
        string memory denom,
        string memory name,
        string memory symbol,
        uint8 decimals
    )
        internal
        returns (address)
    {
        string memory path = string.concat(ICS20Lib.DEFAULT_PORT_ID, "/", clientId, "/", denom);
        return address(new GnoVoucher(name, symbol, decimals, ics20Transfer, path));
    }

    /// @notice Deploys the voucher and registers it with ICS20, which must happen before the denom's first transfer.
    /// The caller needs the role of `setCustomERC20` (ADMIN_ROLE in DeployGnoIBC, so: before the hand-over).
    function register(
        address ics20Transfer,
        string memory clientId,
        string memory denom,
        string memory name,
        string memory symbol,
        uint8 decimals
    )
        internal
        returns (address voucher)
    {
        voucher = deploy(ics20Transfer, clientId, denom, name, symbol, decimals);
        ICS20Transfer(ics20Transfer)
            .setCustomERC20(string.concat(ICS20Lib.DEFAULT_PORT_ID, "/", clientId, "/", denom), voucher);
    }
}
