// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import { IMintableAndBurnable } from "@eureka/interfaces/IMintableAndBurnable.sol";

/// @title The ERC20 voucher of a gno.land denom
/// @notice ICS20 carries amounts in base units, so a voucher must report the decimals of its denom on gno.land
/// (6 for ugnot) for wallets to show the right value. The IBCERC20 that ICS20Transfer deploys on first receipt
/// reports 18 and cannot be changed, so each gno.land denom gets this token instead, registered with
/// ICS20Transfer.setCustomERC20 before its first transfer.
/// @dev Only ICS20Transfer mints and burns, which it does on the client's escrow only. Unlike IBCERC20 the token
/// cannot check the escrow address itself: ICS20Transfer creates a client's escrow on its first packet, after
/// the voucher has to be registered.
contract GnoVoucher is ERC20, IMintableAndBurnable {
    /// @notice The ICS20Transfer contract.
    address public immutable ics20;
    /// @notice The ICS20 denom on this chain, e.g. "transfer/client-0/ugnot".
    string public fullDenomPath;
    uint8 private immutable _decimals;

    error GnoVoucherUnauthorized(address caller);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address ics20_,
        string memory fullDenomPath_
    )
        ERC20(name_, symbol_)
    {
        ics20 = ics20_;
        fullDenomPath = fullDenomPath_;
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IMintableAndBurnable
    function mint(address mintAddress, uint256 amount) external onlyICS20 {
        _mint(mintAddress, amount);
    }

    /// @inheritdoc IMintableAndBurnable
    function burn(address burnAddress, uint256 amount) external onlyICS20 {
        _burn(burnAddress, amount);
    }

    modifier onlyICS20() {
        require(msg.sender == ics20, GnoVoucherUnauthorized(msg.sender));
        _;
    }
}
