// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// GNO: a minimal fork of cosmos/solidity-ibc-eureka solidity-v3.0.2, contracts/ICS20Transfer.sol (MIT), for
// ADR pr6375 E6. Its callbacks are `external` and not `virtual` and `_refundTokens` is private, so it cannot be
// subclassed. Every change to upstream code is marked "GNO:"; the controls themselves are in the section at the end
// (interface: IGnoICS20Controls). Storage: upstream's ERC-7201 namespace is unchanged and the fork's state lives in
// its own (`gno.storage.GnoICS20Transfer`), so a deployed ICS20Transfer proxy upgrades to this implementation in
// place (UUPS) and `initializeGno` sets the fork's state up in the same call.

// GNO: upstream's relative imports point at the vendored eureka tree.
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";

import { IICS20Errors } from "@eureka/errors/IICS20Errors.sol";
import { IEscrow } from "@eureka/interfaces/IEscrow.sol";
import { IIBCApp } from "@eureka/interfaces/IIBCApp.sol";
import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IICS20Transfer, IICS20TransferAccessControlled } from "@eureka/interfaces/IICS20Transfer.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";
import { IMintableAndBurnable } from "@eureka/interfaces/IMintableAndBurnable.sol";
import { IDeprecatedIBCUUPSUpgradeable } from "@eureka/utils/ICS26AdminsDeprecated.sol";
import { IPausable } from "@eureka/interfaces/IPausable.sol";

import { ReentrancyGuardTransient } from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import { SafeERC20 } from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { MulticallUpgradeable } from "@openzeppelin-upgradeable/utils/MulticallUpgradeable.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Bytes } from "@openzeppelin-contracts/utils/Bytes.sol";
import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import { BeaconProxy } from "@openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import { IIBCSenderCallbacks } from "@eureka/interfaces/IIBCSenderCallbacks.sol"; // GNO: was IBCSenderCallbacksLib
import { PausableUpgradeable } from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import { AccessManagedUpgradeable } from "@openzeppelin-upgradeable/access/manager/AccessManagedUpgradeable.sol";

// GNO: the controls' types, the guardians, the buckets and the light client's quarantine.
import { IIBCStore } from "@eureka/interfaces/IIBCStore.sol";
import { IICS02Client } from "@eureka/interfaces/IICS02Client.sol";
import { IGnoICS20ControlsTypes } from "./interfaces/IGnoICS20Controls.sol";
import { IGnoLightClientStatus } from "./interfaces/IGnoLightClientStatus.sol";
import { Guardians } from "./lib/Guardians.sol";
import { LeakyBucket } from "./lib/LeakyBucket.sol";
import { GnoTransferStorage } from "./transfer/GnoTransferStorage.sol";

using SafeERC20 for IERC20;

/// @title GnoICS20Transfer
/// @notice An implementation of the ics20-1 IBC specification for fungible token transfers.
/// GNO: with the controls of ADR pr6375 for the gno.land route: receive limits and default-deny denoms (E5), route
/// flags and the refunds hold (E7), the quarantine (E9), send limits for escrowed tokens, the refund meter with a
/// queue and per-packet send records (§7.13), and route keys with `migrateRoute` (E12).
contract GnoICS20Transfer is
    IICS20Errors,
    IICS20Transfer,
    IIBCApp,
    IPausable,
    ReentrancyGuardTransient,
    MulticallUpgradeable,
    UUPSUpgradeable,
    AccessManagedUpgradeable,
    PausableUpgradeable,
    IGnoICS20ControlsTypes // GNO
{
    /// @notice Storage of the ICS20Transfer contract
    /// @dev It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions when using with
    /// upgradeable contracts.
    /// @param _escrows The escrow contract per client.
    /// @param _ibcERC20Contracts Mapping of non-native denoms to their respective IBCERC20 contracts
    /// @param _ibcERC20Denoms Mapping of IBCERC20 contracts to their respective denoms.
    /// @param _ics26 The ICS26Router contract address. Immutable.
    /// @param _ibcERC20Beacon The address of the IBCERC20 beacon contract. Immutable.
    /// @param _escrowBeacon The address of the Escrow beacon contract. Immutable.
    /// @param _permit2 The permit2 contract. Immutable.
    /// @custom:storage-location erc7201:ibc.storage.ICS20Transfer
    /// GNO: unchanged. `_escrows` and the denom paths of `_ibcERC20Contracts`/`_ibcERC20Denoms` are keyed by route
    /// key instead of client id; the two are the same until a route is migrated.
    struct ICS20TransferStorage {
        mapping(string clientId => IEscrow escrow) _escrows;
        mapping(string => IMintableAndBurnable) _ibcERC20Contracts;
        mapping(address => string) _ibcERC20Denoms;
        IICS26Router _ics26;
        UpgradeableBeacon _ibcERC20Beacon;
        UpgradeableBeacon _escrowBeacon;
        ISignatureTransfer _permit2;
    }

    /// @notice ERC-7201 slot for the ICS20Transfer storage
    /// @dev keccak256(abi.encode(uint256(keccak256("ibc.storage.ICS20Transfer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ICS20TRANSFER_STORAGE_SLOT =
        0x823f7a8ea9ae6df0eb03ec5e1682d7a2839417ad8a91774118e6acf2e8d2f800;

    /// @dev This contract is meant to be deployed by a proxy, so the constructor is not used
    // natlint-disable-next-line MissingNotice
    /// GNO: takes the GnoICS20Controls the fallback serves.
    constructor(address controls) {
        _disableInitializers();
        CONTROLS = controls;
    }

    /// @inheritdoc IICS20Transfer
    function initialize(
        address ics26Router,
        address escrowLogic,
        address ibcERC20Logic,
        address permit2,
        address authority
    )
        public
        onlyVersion(0)
        reinitializer(2)
    {
        __Multicall_init();
        __Pausable_init();
        __AccessManaged_init(authority);

        ICS20TransferStorage storage $ = _getICS20TransferStorage();
        $._ics26 = IICS26Router(ics26Router);
        $._ibcERC20Beacon = new UpgradeableBeacon(ibcERC20Logic, address(this));
        $._escrowBeacon = new UpgradeableBeacon(escrowLogic, address(this));
        $._permit2 = ISignatureTransfer(permit2);
    }

    /// @inheritdoc IICS20Transfer
    function initializeV2(address authority) external onlyVersion(1) reinitializer(2) {
        address ics26_ = address(_getICS20TransferStorage()._ics26);
        require(IDeprecatedIBCUUPSUpgradeable(ics26_).isAdmin(_msgSender()), ICS20Unauthorized(_msgSender()));

        __AccessManaged_init(authority);
    }

    /// @inheritdoc IPausable
    function pause() external restricted {
        _pause();
    }

    /// @inheritdoc IPausable
    function unpause() external restricted {
        _unpause();
    }

    /// @inheritdoc IICS20Transfer
    function getEscrow(string calldata clientId) external view returns (address) {
        return address(_getICS20TransferStorage()._escrows[_routeKey(clientId)]); // GNO: by route key
    }

    /// @inheritdoc IICS20Transfer
    function getEscrowBeacon() external view returns (address) {
        return address(_getICS20TransferStorage()._escrowBeacon);
    }

    /// @inheritdoc IICS20Transfer
    function getIBCERC20Beacon() external view returns (address) {
        return address(_getICS20TransferStorage()._ibcERC20Beacon);
    }

    /// @inheritdoc IICS20Transfer
    function ics26() external view returns (address) {
        return address(_getICS20TransferStorage()._ics26);
    }

    /// @inheritdoc IICS20Transfer
    function getPermit2() external view returns (address) {
        return address(_getICS20TransferStorage()._permit2);
    }

    /// @inheritdoc IICS20Transfer
    function ibcERC20Denom(address token) external view returns (string memory) {
        return _getICS20TransferStorage()._ibcERC20Denoms[token];
    }

    /// @inheritdoc IICS20Transfer
    function ibcERC20Contract(string calldata denom) external view returns (address) {
        // GNO: a denom path over any client id of a route finds the route's token
        address contractAddress =
            address(_getICS20TransferStorage()._ibcERC20Contracts[string(_toRouteDenom(bytes(denom)))]);
        require(contractAddress != address(0), ICS20DenomNotFound(denom));
        return contractAddress;
    }

    /// @inheritdoc IICS20Transfer
    // NOTE: Reentrancy disabled for this function via the `nonReentrant` modifier.
    // slither-disable-next-line reentrancy-no-eth
    function sendTransfer(IICS20TransferMsgs.SendTransferMsg calldata msg_)
        external
        whenNotPaused
        nonReentrant
        returns (uint64)
    {
        require(msg_.amount > 0, IICS20Errors.ICS20InvalidAmount(0));
        // transfer the tokens to us (requires the allowance to be set)
        IEscrow escrow = _getOrCreateEscrow(msg_.sourceClient);
        _transferFrom(_msgSender(), address(escrow), msg_.denom, msg_.amount);
        escrow.recvCallback(msg_.denom, _msgSender(), msg_.amount);

        return _sendTransferFromEscrowWithSender(msg_, address(escrow), _msgSender());
    }

    /// @inheritdoc IICS20Transfer
    // NOTE: Reentrancy disabled for this function via the `nonReentrant` modifier.
    // slither-disable-next-line reentrancy-no-eth
    function sendTransferWithPermit2(
        IICS20TransferMsgs.SendTransferMsg calldata msg_,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint64)
    {
        require(msg_.amount > 0, IICS20Errors.ICS20InvalidAmount(0));
        require(
            permit.permitted.token == msg_.denom,
            IICS20Errors.ICS20Permit2TokenMismatch(permit.permitted.token, msg_.denom)
        );
        // transfer the tokens to us with permit
        IEscrow escrow = _getOrCreateEscrow(msg_.sourceClient);
        _transferFromWithPermit2(_msgSender(), address(escrow), msg_.denom, msg_.amount, permit, signature);
        escrow.recvCallback(msg_.denom, _msgSender(), msg_.amount);

        return _sendTransferFromEscrowWithSender(msg_, address(escrow), _msgSender());
    }

    /// @inheritdoc IICS20TransferAccessControlled
    // NOTE: Reentrancy disabled for this function via the `nonReentrant` modifier.
    // slither-disable-next-line reentrancy-no-eth
    function sendTransferWithSender(
        IICS20TransferMsgs.SendTransferMsg calldata msg_,
        address sender
    )
        external
        whenNotPaused
        nonReentrant
        restricted
        returns (uint64)
    {
        require(msg_.amount > 0, IICS20Errors.ICS20InvalidAmount(0));
        // transfer the tokens to us (requires the allowance to be set)
        IEscrow escrow = _getOrCreateEscrow(msg_.sourceClient);
        _transferFrom(_msgSender(), address(escrow), msg_.denom, msg_.amount);
        escrow.recvCallback(msg_.denom, _msgSender(), msg_.amount);

        return _sendTransferFromEscrowWithSender(msg_, address(escrow), sender);
    }

    /// @notice Send a transfer after the funds have been transferred to escrow
    /// @param msg_ The message for sending a transfer
    /// @param escrow The address of the escrow contract
    /// @param sender The address of the sender, used to refund the tokens if the packet fails
    /// @return sequence The sequence number of the packet created
    // NOTE: We disable reentrancy for public functions.
    // slither-disable-next-line reentrancy-no-eth
    function _sendTransferFromEscrowWithSender(
        IICS20TransferMsgs.SendTransferMsg calldata msg_,
        address escrow,
        address sender
    )
        private
        returns (uint64)
    {
        // GNO: no send on a retired client id: its sends could never be acknowledged or timed out
        require(!_gno().retired[msg_.sourceClient], GnoClientRetired(msg_.sourceClient));
        require(
            !_gno().routes[GnoTransferStorage.routeHash(msg_.sourceClient)].closed, GnoRouteClosed(msg_.sourceClient)
        );
        bool burned; // GNO: a voucher returning to its source: never paused or limited
        string memory fullDenomPath = _getICS20TransferStorage()._ibcERC20Denoms[msg_.denom];
        if (bytes(fullDenomPath).length == 0) {
            // if the denom is not mapped, it is a native token
            fullDenomPath = Strings.toHexString(msg_.denom);
        } else {
            // GNO: the stored path is keyed by route key; on the wire it names the route's current client id
            fullDenomPath = string(GnoTransferStorage.toWireDenom(bytes(fullDenomPath)));
            // we have a mapped denom, so we need to check if the token is returning to source
            bytes memory prefix = ICS20Lib.getDenomPrefix(ICS20Lib.DEFAULT_PORT_ID, msg_.sourceClient);
            // if the denom is prefixed by the port and channel on which we are sending
            // the token, then we must be returning the token back to the chain they originated from
            bool returningToSource = ICS20Lib.hasPrefix(bytes(fullDenomPath), prefix);
            if (returningToSource) {
                // token is returning to source, it is an IBCERC20 and we must burn the token (not keep it in escrow)
                IMintableAndBurnable(msg_.denom).burn(escrow, msg_.amount);
                burned = true; // GNO
            }
        }
        if (!burned) _checkEscrowedSend(msg_.sourceClient, msg_.denom, msg_.amount); // GNO

        IICS20TransferMsgs.FungibleTokenPacketData memory packetData = IICS20TransferMsgs.FungibleTokenPacketData({
            denom: fullDenomPath,
            sender: Strings.toHexString(sender),
            receiver: msg_.receiver,
            amount: msg_.amount,
            memo: msg_.memo
        });

        // GNO: the sequence is kept for the send record
        uint64 sequence = _getICS26Router()
            .sendPacket(
                IICS26RouterMsgs.MsgSendPacket({
                sourceClient: msg_.sourceClient,
                timeoutTimestamp: msg_.timeoutTimestamp,
                payload: IICS26RouterMsgs.Payload({
                sourcePort: ICS20Lib.DEFAULT_PORT_ID,
                destPort: ICS20Lib.DEFAULT_PORT_ID,
                version: ICS20Lib.ICS20_VERSION,
                encoding: ICS20Lib.ICS20_ENCODING,
                value: abi.encode(packetData)
            })
            })
            );
        _recordSend(msg_, sequence, escrow, sender, burned); // GNO
        return sequence;
    }

    /// @inheritdoc IICS20TransferAccessControlled
    function setCustomERC20(string calldata denom, address token) external restricted {
        ICS20TransferStorage storage $ = _getICS20TransferStorage();
        string memory routeDenom = string(_toRouteDenom(bytes(denom))); // GNO: stored by route key
        require(address($._ibcERC20Contracts[routeDenom]) == address(0), IICS20Errors.ICS20DenomAlreadyExists(denom));
        require(
            bytes($._ibcERC20Denoms[token]).length == 0, IICS20Errors.ICS20TokenAlreadyExists($._ibcERC20Denoms[token])
        );

        $._ibcERC20Contracts[routeDenom] = IMintableAndBurnable(token);
        $._ibcERC20Denoms[token] = routeDenom;
    }

    /// @inheritdoc IIBCApp
    // NOTE: Reentrancy disabled for this function via the `nonReentrant` modifier.
    // slither-disable-next-line reentrancy-no-eth
    function onRecvPacket(IIBCAppCallbacks.OnRecvPacketCallback calldata msg_)
        // solhint-disable-previous-line function-max-lines
        external
        onlyRouter
        nonReentrant
        whenNotPaused
        returns (bytes memory)
    {
        // Since this function mostly returns acks, also when it fails, the ics26router (the caller) will log the ack
        require(
            keccak256(bytes(msg_.payload.version)) == ICS20Lib.KECCAK256_ICS20_VERSION,
            ICS20UnexpectedVersion(ICS20Lib.ICS20_VERSION, msg_.payload.version)
        );
        require(
            keccak256(bytes(msg_.payload.sourcePort)) == ICS20Lib.KECCAK256_DEFAULT_PORT_ID,
            ICS20InvalidPort(ICS20Lib.DEFAULT_PORT_ID, msg_.payload.sourcePort)
        );
        require(
            keccak256(bytes(msg_.payload.encoding)) == ICS20Lib.KECCAK256_ICS20_ENCODING,
            ICS20UnexpectedEncoding(ICS20Lib.ICS20_ENCODING, msg_.payload.encoding)
        );
        require(
            keccak256(bytes(msg_.payload.destPort)) == ICS20Lib.KECCAK256_DEFAULT_PORT_ID,
            ICS20InvalidPort(ICS20Lib.DEFAULT_PORT_ID, msg_.payload.destPort)
        );

        IICS20TransferMsgs.FungibleTokenPacketData memory packetData =
            abi.decode(msg_.payload.value, (IICS20TransferMsgs.FungibleTokenPacketData));
        require(packetData.amount > 0, ICS20InvalidAmount(0));
        bytes32 route = _checkReceiveRoute(msg_.destinationClient); // GNO: retired, recovery, flags, quarantine

        address receiver = ICS20Lib.mustHexStringToAddress(packetData.receiver);
        IEscrow escrow = _getOrCreateEscrow(msg_.destinationClient);
        bytes memory denomBz = bytes(packetData.denom);
        bytes memory prefix = ICS20Lib.getDenomPrefix(msg_.payload.sourcePort, msg_.sourceClient);

        // This is the prefix that would have been prefixed to the denomination
        // on sender chain IF and only if the token originally came from the
        // receiving chain.
        //
        // NOTE: We use SourcePort and SourceChannel here, because the counterparty
        // chain would have prefixed with DestPort and DestChannel when originally
        // receiving this token.
        bool returningToOrigin = ICS20Lib.hasPrefix(denomBz, prefix);
        address erc20Address;
        if (returningToOrigin) {
            // we are the origin source of this token:
            // Case 1: Forwarded IBCERC20
            // Case 2: Native ERC20

            // remove the first hop to unwind the trace
            bytes memory newDenom = Bytes.slice(denomBz, prefix.length);

            bool isAddress;
            (isAddress, erc20Address) = Strings.tryParseAddress(string(newDenom));
            if (!isAddress || erc20Address == address(0)) {
                // Case 1: Forwarded IBCERC20
                // we are the origin source and the token must be an IBCERC20 (since it is not a native token)
                // GNO: looked up by route key
                erc20Address = address(_getICS20TransferStorage()._ibcERC20Contracts[string(_toRouteDenom(newDenom))]);
                require(erc20Address != address(0), ICS20DenomNotFound(string(newDenom)));
            } // else: Case 2: "Native" ERC20
            _chargeReceive(route, msg_.destinationClient, erc20Address, packetData.amount); // GNO: E5
        } else {
            // we are not origin source, i.e. sender chain is the origin source: add denom trace and mint vouchers
            bytes memory newDenomPrefix = ICS20Lib.getDenomPrefix(msg_.payload.destPort, msg_.destinationClient);
            // NOTE: encodePacked is required by the ICS20 spec.
            // slither-disable-next-line encode-packed-collision
            bytes memory newDenom = abi.encodePacked(newDenomPrefix, denomBz);

            // GNO: default deny. Only a denom whose voucher governance registered (setCustomERC20, decision kind 5)
            // is received; no stock 18-decimal IBCERC20 is ever created for a gno.land denom.
            erc20Address = address(_getICS20TransferStorage()._ibcERC20Contracts[string(_toRouteDenom(newDenom))]);
            require(erc20Address != address(0), GnoDenomNotRegistered(string(newDenom)));
            _chargeReceive(route, msg_.destinationClient, erc20Address, packetData.amount); // GNO: E5
            IMintableAndBurnable(erc20Address).mint(address(escrow), packetData.amount);
        }

        // transfer the tokens to the receiver
        escrow.send(IERC20(erc20Address), receiver, packetData.amount);

        return ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON;
    }

    /// @inheritdoc IIBCApp
    // GNO: not `whenNotPaused`: a pause never blocks acknowledgements or refunds (ADR §7.3).
    function onAcknowledgementPacket(IIBCAppCallbacks.OnAcknowledgementPacketCallback calldata msg_)
        external
        onlyRouter
        nonReentrant
    {
        IICS20TransferMsgs.FungibleTokenPacketData memory packetData =
            abi.decode(msg_.payload.value, (IICS20TransferMsgs.FungibleTokenPacketData));

        if (keccak256(msg_.acknowledgement) == ICS24Host.KECCAK256_UNIVERSAL_ERROR_ACK) {
            // if the acknowledgement is an error, we must refund the tokens to the sender
            // GNO: paid at once, or queued under the refund meter or the refunds hold; the sender is notified
            // when its refund is paid, and its notification failing never rolls the refund back
            _refundTokens(
                msg_.payload.sourcePort,
                msg_.sourceClient,
                msg_.sequence,
                packetData,
                Outcome.ErrorAck,
                abi.encodeCall(IIBCSenderCallbacks.onAckPacket, (false, msg_))
            );
        } else {
            // GNO: the outcome attached to the send record; a notification failing never rolls it back
            address sender = ICS20Lib.mustHexStringToAddress(packetData.sender);
            _ackHook(
                msg_.sourceClient,
                msg_.sequence,
                Outcome.Success,
                address(0),
                sender,
                0,
                abi.encodeCall(IIBCSenderCallbacks.onAckPacket, (true, msg_))
            );
        }
    }

    /// @inheritdoc IIBCApp
    // GNO: not `whenNotPaused`: a pause never blocks timeouts or refunds (ADR §7.3).
    function onTimeoutPacket(IIBCAppCallbacks.OnTimeoutPacketCallback calldata msg_) external onlyRouter nonReentrant {
        IICS20TransferMsgs.FungibleTokenPacketData memory packetData =
            abi.decode(msg_.payload.value, (IICS20TransferMsgs.FungibleTokenPacketData));
        // GNO: paid at once, or queued under the refund meter or the refunds hold; notified when paid
        _refundTokens(
            msg_.payload.sourcePort,
            msg_.sourceClient,
            msg_.sequence,
            packetData,
            Outcome.Timeout,
            abi.encodeCall(IIBCSenderCallbacks.onTimeoutPacket, (msg_))
        );
    }

    /// @notice Refund the tokens to the sender
    /// @param sourcePort The source port of the packet
    /// @param sourceClient The source client of the packet
    /// @param packetData The packet data
    /// GNO: also takes the sequence, the outcome and the sender's notification; the refund is attached to the
    /// packet's send record and paid by the controls' `ackHook` (at once, or queued). Upstream's return values (the
    /// token and the refundee) were unused and are dropped.
    function _refundTokens(
        string calldata sourcePort,
        string calldata sourceClient,
        uint64 sequence,
        IICS20TransferMsgs.FungibleTokenPacketData memory packetData,
        Outcome outcome,
        bytes memory notice
    )
        private
    {
        ICS20TransferStorage storage $ = _getICS20TransferStorage();
        IEscrow escrow = $._escrows[_routeKey(sourceClient)]; // GNO: by route key
        require(address(escrow) != address(0), IICS20Errors.ICS20EscrowNotFound(sourceClient));

        address refundee = ICS20Lib.mustHexStringToAddress(packetData.sender);
        address erc20Address;

        // if the denom is prefixed by the port and channel on which we are sending
        // the token, then we must be returning the token back to the chain they originated from
        bytes memory prefix = ICS20Lib.getDenomPrefix(sourcePort, sourceClient);
        bool isDestSource = ICS20Lib.hasPrefix(bytes(packetData.denom), prefix);
        string memory routeDenom = string(_toRouteDenom(bytes(packetData.denom))); // GNO: lookups by route key
        if (isDestSource) {
            // receiving chain is source of the token, so we've received and mapped this token before
            erc20Address = address($._ibcERC20Contracts[routeDenom]);
            require(erc20Address != address(0), ICS20DenomNotFound(packetData.denom));
            // GNO: the burned voucher is minted back when the refund is paid (`tryPayRefund`)
        } else {
            // the receiving chain is not the source of the token, so the token is either a native token
            // or we are a middle chain and the token was minted (and mapped) here.
            erc20Address = address($._ibcERC20Contracts[routeDenom]);
            if (erc20Address == address(0)) {
                // the token is not mapped, so the token must be native
                erc20Address = ICS20Lib.mustHexStringToAddress(packetData.denom);
                require(erc20Address != address(0), ICS20DenomNotFound(packetData.denom));
            }
        }

        // GNO: instead of `escrow.send(IERC20(erc20Address), refundee, packetData.amount)`
        _ackHook(sourceClient, sequence, outcome, erc20Address, refundee, packetData.amount, notice);
    }

    /// @notice Transfer tokens from sender to receiver
    /// @param sender The sender of the tokens
    /// @param receiver The receiver of the tokens
    /// @param tokenContract The address of the token contract
    /// @param amount The amount of tokens to transfer
    function _transferFrom(address sender, address receiver, address tokenContract, uint256 amount) private {
        // we snapshot current balance of this token
        uint256 ourStartingBalance = IERC20(tokenContract).balanceOf(receiver);

        IERC20(tokenContract).safeTransferFrom(sender, receiver, amount);

        // check what this particular ERC20 implementation actually gave us, since it doesn't
        // have to be at all related to the _amount
        uint256 actualEndingBalance = IERC20(tokenContract).balanceOf(receiver);

        uint256 expectedEndingBalance = ourStartingBalance + amount;
        // a very strange ERC20 may trigger this condition, if we didn't have this we would
        // underflow, so it's mostly just an error message printer
        // NOTE: This is not a security check, but rather a sanity check.
        // slither-disable-next-line incorrect-equality
        require(
            actualEndingBalance > ourStartingBalance && actualEndingBalance == expectedEndingBalance,
            ICS20UnexpectedERC20Balance(expectedEndingBalance, actualEndingBalance)
        );
    }

    /// @notice Transfer tokens from sender to receiver using permit2
    /// @param sender The sender of the tokens
    /// @param receiver The receiver of the tokens
    /// @param tokenContract The address of the token contract
    /// @param amount The amount of tokens to transfer
    /// @param permit The permit data
    /// @param signature The signature of the permit data
    // NOTE: Balance reentrancy here is intentionally allowed, as we are checking the balance before and after
    // slither-disable-next-line reentrancy-balance
    function _transferFromWithPermit2(
        address sender,
        address receiver,
        address tokenContract,
        uint256 amount,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    )
        private
    {
        // we snapshot current balance of this token
        uint256 ourStartingBalance = IERC20(tokenContract).balanceOf(receiver);

        _getPermit2()
            .permitTransferFrom(
                permit,
                ISignatureTransfer.SignatureTransferDetails({ to: receiver, requestedAmount: amount }),
                sender,
                signature
            );

        // check what this particular ERC20 implementation actually gave us, since it doesn't
        // have to be at all related to the _amount
        uint256 actualEndingBalance = IERC20(tokenContract).balanceOf(receiver);

        uint256 expectedEndingBalance = ourStartingBalance + amount;
        // a very strange ERC20 may trigger this condition, if we didn't have this we would
        // underflow, so it's mostly just an error message printer
        // NOTE: This is not a security check, but rather a sanity check.
        // slither-disable-next-line incorrect-equality
        require(
            actualEndingBalance > ourStartingBalance && actualEndingBalance == expectedEndingBalance,
            ICS20UnexpectedERC20Balance(expectedEndingBalance, actualEndingBalance)
        );
    }

    // GNO: `_getOrCreateIBCERC20` removed: a denom without a registered voucher is refused (default deny), so the
    // fork never creates an IBCERC20. The beacon stays for storage compatibility.

    /// @notice Returns the escrow contract for a client
    /// @param clientId The client ID
    /// @return The escrow contract address
    function _getOrCreateEscrow(string memory clientId) private returns (IEscrow) {
        ICS20TransferStorage storage $ = _getICS20TransferStorage();
        clientId = _routeKey(clientId); // GNO: one escrow per route

        IEscrow escrow = $._escrows[clientId];
        if (address(escrow) == address(0)) {
            escrow = IEscrow(
                address(
                    new BeaconProxy(
                        address($._escrowBeacon), abi.encodeCall(IEscrow.initialize, (address(this), authority()))
                    )
                )
            );
            $._escrows[clientId] = escrow;
        }

        return escrow;
    }

    /// @notice Returns the storage of the ICS20Transfer contract
    /// @return $ The storage of the ICS20Transfer contract
    function _getICS20TransferStorage() private pure returns (ICS20TransferStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := ICS20TRANSFER_STORAGE_SLOT
        }
    }

    /// @inheritdoc UUPSUpgradeable
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override restricted { }

    /// @inheritdoc IICS20TransferAccessControlled
    function upgradeEscrowTo(address newEscrowLogic) external restricted {
        _getICS20TransferStorage()._escrowBeacon.upgradeTo(newEscrowLogic);
    }

    /// @inheritdoc IICS20TransferAccessControlled
    function upgradeIBCERC20To(address newIBCERC20Logic) external restricted {
        _getICS20TransferStorage()._ibcERC20Beacon.upgradeTo(newIBCERC20Logic);
    }

    /// @notice Returns the ICS26Router contract
    /// @return The ICS26Router contract address
    function _getICS26Router() private view returns (IICS26Router) {
        return _getICS20TransferStorage()._ics26;
    }

    /// @notice Returns the permit2 contract
    /// @return The permit2 contract address
    function _getPermit2() private view returns (ISignatureTransfer) {
        return _getICS20TransferStorage()._permit2;
    }

    /// @notice Modifier to check if the caller is the ICS26Router contract
    modifier onlyRouter() {
        require(_msgSender() == address(_getICS26Router()), ICS20Unauthorized(_msgSender()));
        _;
    }

    /// @notice Modifier to check if the initialization version matches the expected version
    /// @param version The expected current version of the contract
    modifier onlyVersion(uint256 version) {
        require(_getInitializedVersion() == version, InvalidInitialization());
        _;
    }

    // =================================================================================================== GNO ==
    // Everything below is new: the hot path of the controls of ADR pr6375. Their governance, guardian, claim and
    // view functions (IGnoICS20Controls) run in GnoICS20Controls, which `fallback` delegatecalls, so this contract
    // stays under EIP-170; both share GnoTransferStorage's layout.

    /// @notice GnoICS20Controls, fixed with this implementation (its address is in this code, so a code hash of the
    /// implementation pins it).
    address public immutable CONTROLS;

    /// @notice Serves IGnoICS20Controls from GnoICS20Controls, in this contract's storage and authority.
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        address controls = CONTROLS;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), controls, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _gno() private pure returns (GnoTransferStorage.Layout storage) {
        return GnoTransferStorage.layout();
    }

    function _routeKey(string memory clientId) private view returns (string memory) {
        return GnoTransferStorage.routeKey(clientId);
    }

    function _toRouteDenom(bytes memory path) private view returns (bytes memory) {
        return GnoTransferStorage.toRouteDenom(path);
    }

    /// @notice Refuses a receive on a retired client id, on a route under an emergency recovery, a flag or a
    /// quarantine; returns the route.
    function _checkReceiveRoute(string calldata clientId) private view returns (bytes32 route) {
        GnoTransferStorage.Layout storage g = _gno();
        require(!g.retired[clientId], GnoClientRetired(clientId));
        route = GnoTransferStorage.routeHash(clientId);
        GnoTransferStorage.Route storage r = g.routes[route];
        require(!r.recoveryBlocked, GnoRouteRecovering(clientId));
        require(!Guardians.anyFlag(g.keys, r.flags), GnoRoutePaused(clientId));
        require(!r.closed, GnoRouteClosed(clientId));
        if (r.quarantineSeconds != 0 || r.quarantineDeadline != 0) {
            address lc = address(IICS02Client(address(_getICS26Router())).getClient(clientId));
            uint64 id;
            uint64 time;
            try IGnoLightClientStatus(lc).lastTransition() returns (uint64 i, uint64 t) {
                (id, time) = (i, t);
            } catch {
                revert GnoQuarantineUnknown(clientId);
            }
            uint256 until = GnoTransferStorage.quarantineUntil(r, lc, id, time);
            // forge-lint: disable-next-line(block-timestamp)
            require(block.timestamp >= until, GnoQuarantined(clientId, until));
        }
    }

    /// @notice E5: the per-message maximum and the day cap of the route and token; refused without limits.
    function _chargeReceive(bytes32 route, string calldata clientId, address token, uint256 amount) private {
        GnoTransferStorage.TokenControls storage t = _gno().tokens[route][token];
        require(t.set, GnoLimitsNotSet(clientId, token));
        uint256 maxPerMessage = t.limits.maxPerMessage;
        require(amount <= maxPerMessage, GnoOverMaxPerMessage(token, amount, maxPerMessage));
        require(
            LeakyBucket.charge(t.received, t.limits.dayCap, amount, uint64(block.timestamp)),
            GnoOverDayCap(token, amount, t.limits.dayCap)
        );
    }

    /// @notice A token leaving through escrow (not a returning voucher): refused under a flag or an emergency
    /// recovery of the route, without limits, or outside `sendMin`/`sendMax`.
    function _checkEscrowedSend(string calldata clientId, address token, uint256 amount) private view {
        GnoTransferStorage.Layout storage g = _gno();
        bytes32 route = GnoTransferStorage.routeHash(clientId);
        GnoTransferStorage.Route storage r = g.routes[route];
        require(!r.recoveryBlocked, GnoRouteRecovering(clientId));
        require(!Guardians.anyFlag(g.keys, r.flags), GnoRoutePaused(clientId));
        GnoTransferStorage.TokenControls storage t = g.tokens[route][token];
        require(t.set, GnoLimitsNotSet(clientId, token));
        uint256 sendMax = t.limits.sendMax;
        require(sendMax == 0 || amount <= sendMax, GnoSendAboveMax(token, amount, sendMax));
        uint256 sendMin = t.limits.sendMin;
        require(amount >= sendMin, GnoSendBelowMin(token, amount, sendMin));
    }

    /// @notice Writes the packet's send record (§7.13), in the transaction of the send.
    function _recordSend(
        IICS20TransferMsgs.SendTransferMsg calldata msg_,
        uint64 sequence,
        address escrow,
        address sender,
        bool burned
    )
        private
    {
        bytes32 commitment = IIBCStore(address(_getICS26Router()))
            .getCommitment(ICS24Host.packetCommitmentKeyCalldata(msg_.sourceClient, sequence));
        SendRecord storage rec = _gno().records[keccak256(bytes(msg_.sourceClient))][sequence];
        rec.commitment = commitment;
        rec.sender = sender;
        rec.token = msg_.denom;
        rec.escrow = escrow;
        rec.timeoutTimestamp = msg_.timeoutTimestamp;
        rec.sendBlock = uint64(block.number);
        rec.burned = burned;
        rec.amount = msg_.amount;
        emit GnoSendRecorded(msg_.sourceClient, sequence, commitment, msg_.denom, msg_.amount);
    }

    /// @notice The controls' `ackHook`, run in this contract's storage: attaches an ack's or timeout's outcome to
    /// the send record and settles its refund (GnoICS20Controls). A consume-once transient flag lets only this call
    /// reach the hook: the fallback cannot.
    function _ackHook(
        string calldata clientId,
        uint64 sequence,
        Outcome outcome,
        address token,
        address refundee,
        uint256 amount,
        bytes memory notice
    )
        private
    {
        address controls = CONTROLS;
        bytes memory call = abi.encodeWithSignature(
            "ackHook(string,uint64,uint8,address,address,uint256,bytes)",
            clientId,
            sequence,
            outcome,
            token,
            refundee,
            amount,
            notice
        );
        // solhint-disable-next-line no-inline-assembly
        assembly {
            tstore(0xfe384f8ea4975d6b603976442788326f3f0c6e1e07e29205223544c80bcce885, 1)
        }
        (bool ok, bytes memory ret) = controls.delegatecall(call);
        if (!ok) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
