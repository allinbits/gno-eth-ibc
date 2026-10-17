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
import { IGnoLightClientMsgs } from "../../src/msgs/IGnoLightClientMsgs.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { IICS02Client } from "@eureka/interfaces/IICS02Client.sol";
import { IGnoICS20Controls } from "../../src/interfaces/IGnoICS20Controls.sol";
import { ILightClient } from "@eureka/interfaces/ILightClient.sol";
import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";

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

    /// @notice Fresh storage slots each callback writes (a bookkeeping adapter needing more than 100,000 gas).
    uint256 public cost;
    uint256 public successes;
    mapping(uint256 => uint256) internal book;

    function setCost(uint256 c) external {
        cost = c;
    }

    function _book() private {
        uint256 base = notices << 32;
        for (uint256 i = 0; i < cost; i++) {
            book[base + i] = i + 1;
        }
    }

    bytes32 public lastAck; // the hash of the last success ack announced

    function onAckPacket(bool success, IIBCAppCallbacks.OnAcknowledgementPacketCallback calldata cb) external {
        while (burn) { } // burns all the gas it is given
        require(msg.sender == address(ics20), "only the transfer app");
        require(!refuse, "refused");
        _book();
        notices++;
        if (success) {
            successes++;
            lastAck = keccak256(cb.acknowledgement);
        } else {
            _forward();
        }
    }

    function onTimeoutPacket(IIBCAppCallbacks.OnTimeoutPacketCallback calldata) external {
        while (burn) { }
        require(msg.sender == address(ics20), "only the transfer app");
        require(!refuse, "refused");
        _book();
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

/// @notice A token whose transfers to `burnFor` burn every unit of gas they are given.
contract GasBurnToken is ERC20 {
    address public burnFor;

    constructor() ERC20("Burn", "BURN") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBurnFor(address a) external {
        burnFor = a;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to != address(0) && to == burnFor) {
            uint256 x;
            while (true) {
                x++;
            }
        }
    }
}

/// @notice A token whose balanceOf is expensive (about 60,000 gas of computation, warm or cold), its transfers
/// ordinary.
contract CostlyBalanceToken is ERC20 {
    constructor() ERC20("Costly", "COST") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function balanceOf(address a) public view override returns (uint256) {
        bytes32 x = bytes32(uint256(uint160(a)));
        for (uint256 i = 0; i < 600; i++) {
            x = keccak256(abi.encode(x, i));
        }
        return super.balanceOf(a) + (uint256(x) == 0 ? 1 : 0);
    }
}

/// @notice A gno.land light client whose status views (isFrozen, isExpired, lastTransition) misbehave on demand:
/// mode 1 missing (an empty revert), 2 reverting, 3 a short return, 4 an out-of-range value; 0 answers healthy.
contract StatusMock {
    mapping(bytes4 => uint8) public mode;

    function setMode(bytes4 selector, uint8 m) external {
        mode[selector] = m;
    }

    function getClientState() external pure returns (bytes memory) {
        IGnoLightClientMsgs.ClientState memory cs;
        cs.chainId = "gno-test";
        return abi.encode(cs);
    }

    fallback(bytes calldata) external returns (bytes memory) {
        bytes4 s = msg.sig;
        uint8 m = mode[s];
        if (m == 1) revert();
        if (m == 2) revert("broken");
        if (s == bytes4(keccak256("lastTransition()"))) {
            if (m == 3) return hex"00";
            if (m == 4) return abi.encode(uint256(1) << 70, uint256(0));
            return abi.encode(uint64(0), uint64(0));
        }
        if (m == 3) return hex"0000";
        if (m == 4) return abi.encode(uint256(2));
        return abi.encode(false);
    }
}

/// @notice A contract sender whose IIBCSenderCallbacks callback tries to re-enter the transfer app (a claim): the
/// shared lock refuses it; the revert data it got is kept.
contract ReentrantSender is IIBCSenderCallbacks {
    IICS20Transfer public immutable ics20;
    IERC20 public immutable token;
    bytes public reentryReason;
    uint256 public callbacks;

    constructor(IICS20Transfer ics20_, IERC20 token_) {
        (ics20, token) = (ics20_, token_);
        token_.approve(address(ics20_), type(uint256).max);
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

    function _reenter() private {
        callbacks++;
        try IGnoICS20Controls(address(ics20)).claim("client-0", address(token), 1) {
            reentryReason = "";
        } catch (bytes memory r) {
            reentryReason = r;
        }
    }

    function onAckPacket(bool, IIBCAppCallbacks.OnAcknowledgementPacketCallback calldata) external {
        _reenter();
    }

    function onTimeoutPacket(IIBCAppCallbacks.OnTimeoutPacketCallback calldata) external {
        _reenter();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IIBCSenderCallbacks).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @notice A token whose transfers to `mute` revert with no data at all (a bare `revert()`).
contract MuteRevertToken is ERC20 {
    address public mute;

    constructor() ERC20("Mute", "MUTE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMute(address a) external {
        mute = a;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && to == mute) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(0, 0)
            }
        }
        super._update(from, to, value);
    }
}

/// @notice Tries the system's privileged entry points from inside a call it was given, records what each answered.
abstract contract Reenterer {
    address public ics20;
    address public admin;
    string public clientId;
    uint256 public attempts;
    uint256 public succeeded;
    bytes[] internal reasons;

    function arm(address ics20_, address admin_, string calldata clientId_) external {
        (ics20, admin, clientId) = (ics20_, admin_, clientId_);
    }

    function reason(uint256 i) external view returns (bytes memory) {
        return reasons[i];
    }

    /// @notice A call counts as getting through if it succeeded, except `drain`, which inside a transfer-app entry
    /// point succeeds and records nothing: it gets through only if it recorded something.
    function _try(address target, bytes memory data) private {
        (bool ok, bytes memory r) = target.call(data);
        bool drained = bytes4(data) == bytes4(keccak256("drain()"));
        if (ok && (!drained || abi.decode(r, (uint256)) != 0)) succeeded++;
        reasons.push(r);
    }

    function _reenter() internal {
        if (ics20 == address(0) || attempts != 0) return;
        attempts++;
        _try(ics20, abi.encodeWithSignature("claim(string,address,uint256)", clientId, address(0), 1));
        _try(ics20, abi.encodeWithSignature("continueReopen(string,uint256)", clientId, 1));
        _try(admin, abi.encodeWithSignature("drain()"));
        _try(admin, abi.encodeWithSignature("execute(uint64)", uint64(1)));
        _try(admin, abi.encodeWithSignature("executeRecovery()"));
    }
}

/// @notice A verifier that, asked to verify, tries the privileged entry points first (and then proves anything).
contract ReentrantVerifier is ILightClient, Reenterer {
    function updateClient(bytes calldata) external pure returns (ILightClientMsgs.UpdateResult) {
        return ILightClientMsgs.UpdateResult.Update;
    }

    function verifyMembership(ILightClientMsgs.MsgVerifyMembership calldata) external returns (uint256) {
        _reenter();
        return block.timestamp;
    }

    function verifyNonMembership(ILightClientMsgs.MsgVerifyNonMembership calldata) external returns (uint256) {
        _reenter();
        return block.timestamp;
    }

    function misbehaviour(bytes calldata) external { }

    function getClientState() external pure returns (bytes memory) {
        IGnoLightClientMsgs.ClientState memory cs;
        cs.chainId = "gno-test";
        return abi.encode(cs);
    }

    function lastTransition() external pure returns (uint64, uint64) {
        return (0, 0);
    }

    function isFrozen() external pure returns (bool) {
        return false;
    }

    function isExpired() external pure returns (bool) {
        return false;
    }
}

/// @notice A permit2 that tries the privileged entry points before moving the tokens.
contract ReentrantPermit2 is Reenterer {
    function permitTransferFrom(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        ISignatureTransfer.SignatureTransferDetails calldata details,
        address owner,
        bytes calldata
    )
        external
    {
        _reenter();
        IERC20(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount);
    }
}
