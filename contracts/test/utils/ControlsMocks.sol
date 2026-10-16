// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC165 } from "@openzeppelin-contracts/utils/introspection/IERC165.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";

import { IIBCSenderCallbacks } from "@eureka/interfaces/IIBCSenderCallbacks.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";
import { IICS20Transfer } from "@eureka/interfaces/IICS20Transfer.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";

import { UpgradeableBeacon } from "@openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

import { GnoICS20Transfer } from "../../src/GnoICS20Transfer.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { IICS02Client } from "@eureka/interfaces/IICS02Client.sol";
import { IGnoICS20Controls } from "../../src/interfaces/IGnoICS20Controls.sol";

/// @notice A Permit2 stand-in that moves the tokens without checking a signature (the fork's balance check still
/// runs).
contract MockPermit2 {
    function permitTransferFrom(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        ISignatureTransfer.SignatureTransferDetails calldata details,
        address owner,
        bytes calldata
    )
        external
    {
        IERC20(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount);
    }
}

/// @notice A contract sender adapter (as integrations build them): it sends through ICS20 and, when told its packet
/// failed, forwards the refunded tokens to its owner, which reverts unless the refund was paid first.
contract SenderAdapter is IIBCSenderCallbacks {
    IICS20Transfer public immutable ics20;
    IERC20 public immutable token;
    address public immutable owner;
    bool public refuse;
    uint256 public notices;

    constructor(IICS20Transfer ics20_, IERC20 token_, address owner_) {
        (ics20, token, owner) = (ics20_, token_, owner_);
        token_.approve(address(ics20_), type(uint256).max);
    }

    bool public burn;

    function setRefuse(bool r) external {
        refuse = r;
    }

    function setBurn(bool b) external {
        burn = b;
    }

    function sendWithMemo(uint256 amount, string calldata clientId, string calldata memo) external returns (uint64) {
        return ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg({
                denom: address(token),
                amount: amount,
                receiver: "g1receiver",
                sourceClient: clientId,
                destPort: "transfer",
                timeoutTimestamp: uint64(block.timestamp + 600),
                memo: memo
            })
        );
    }

    function send(uint256 amount, string calldata clientId) external returns (uint64) {
        return ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg({
                denom: address(token),
                amount: amount,
                receiver: "g1receiver",
                sourceClient: clientId,
                destPort: "transfer",
                timeoutTimestamp: uint64(block.timestamp + 600),
                memo: ""
            })
        );
    }

    function onAckPacket(bool success, IIBCAppCallbacks.OnAcknowledgementPacketCallback calldata) external {
        while (burn) { } // burns all the gas it is given
        require(msg.sender == address(ics20), "only the transfer app");
        require(!refuse, "refused");
        notices++;
        if (!success) _forward();
    }

    function onTimeoutPacket(IIBCAppCallbacks.OnTimeoutPacketCallback calldata) external {
        while (burn) { }
        require(msg.sender == address(ics20), "only the transfer app");
        require(!refuse, "refused");
        notices++;
        _forward();
    }

    function _forward() private {
        uint256 b = token.balanceOf(address(this));
        require(b != 0, "nothing refunded yet");
        token.transfer(owner, b);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IIBCSenderCallbacks).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @notice A token whose transfer to `trap` re-enters the controls' `claim` (a reentrancy probe).
contract ReentrantToken is ERC20 {
    IGnoICS20Controls public controls;
    string public clientId;
    address public trap;
    bool public reentered;
    bool public reentryRefused;

    constructor() ERC20("Reentrant", "RNT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(IGnoICS20Controls c, string calldata id, address t) external {
        (controls, clientId, trap) = (c, id, t);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == trap && address(controls) != address(0) && !reentered) {
            reentered = true;
            try controls.claim(clientId, address(this), 20) { }
            catch {
                reentryRefused = true;
            }
        }
    }
}

/// @notice A transfer implementation whose extra function re-points the escrow beacon (it runs as the proxy, the
/// beacons' owner): what a kind 7 call must never get away with.
contract BeaconSwappingFork is GnoICS20Transfer {
    constructor(address controls) GnoICS20Transfer(controls) { }

    function swapEscrowBeacon(address impl) external {
        UpgradeableBeacon(this.getEscrowBeacon()).upgradeTo(impl);
    }
}

/// @notice An executor whose pinned allow-list admits one harmless migration call: the router's `getClient`.
contract AllowingExec is IBCAdminExec {
    constructor(address r, address am, address t) IBCAdminExec(r, am, t) { }

    function migrationAllowed(address proxy, bytes4 selector) public pure override returns (bool) {
        return proxy != address(0) && selector == IICS02Client.getClient.selector;
    }
}

/// @notice A token that runs one call when it next pays `hookOn` (a transfer hook a payment cannot stop).
contract HookToken is ERC20 {
    address public hookOn;
    address public target;
    bytes public data;

    constructor() ERC20("Hook", "HOOK") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address on, address t, bytes calldata d) external {
        (hookOn, target, data) = (on, t, d);
    }

    /// @notice Whether the last hook call succeeded, and what it returned.
    bool public hookOk;
    bytes public hookRet;
    mapping(address => bool) public blocked;

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
        if (to != address(0) && to == hookOn) {
            hookOn = address(0);
            (hookOk, hookRet) = target.call(data);
        }
    }
}

/// @notice A fork that answers an older controls version than the running one (a downgrade).
contract OlderFork is GnoICS20Transfer {
    constructor(address controls) GnoICS20Transfer(controls) { }

    function gnoControlsVersion() external pure override returns (uint256) {
        return 0;
    }
}
