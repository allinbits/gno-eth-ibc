// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @notice An ERC20 that refuses transfers to blocked addresses (as USDC and USDT blacklists do).
contract RefusingToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Refusing", "RFS") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}
