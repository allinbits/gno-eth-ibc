// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IICS02Client } from "@eureka/interfaces/IICS02Client.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS20Transfer } from "@eureka/interfaces/IICS20Transfer.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { IIBCAdmin } from "../interfaces/IIBCAdmin.sol";
import { IGnoICS20Controls } from "../interfaces/IGnoICS20Controls.sol";
import { IGnoLightClientMsgs as Msgs } from "../msgs/IGnoLightClientMsgs.sol";
import { IBCAdminStorage as S } from "./IBCAdminStorage.sol";

interface IAdminViews {
    function router() external view returns (address);
    function ics20() external view returns (address);
    function govClient() external view returns (string memory);
    function gnoChainId() external view returns (string memory);
}

interface IGnoVerifierViews {
    function getClientState() external view returns (bytes memory);
    function getConsensusState(uint64 height) external view returns (Msgs.ConsensusState memory);
}

interface IVoucherBinding {
    function ics20() external view returns (address);
}

/// @title `finishSetup`'s launch checks 11 to 15 (ADR pr6375 E11)
/// @notice A view contract IBCAdmin's constructor deploys (so its code is part of IBCAdmin's build), which checks the
/// deployment's record (`IIBCAdmin.Launch`) against the chain. It never compares against state a third party can
/// advance: the verifier's original checkpoint and its parameters no update changes, not its current height.
contract IBCAdminLaunchCheck {
    /// @notice The hash of a client state's parameters no update changes (everything but its latest height and its
    /// frozen flag): `keccak256(abi.encode(chainId, revisionNumber, trustLevel, trustingPeriod, maxClockDrift))`.
    function clientParamsHash(Msgs.ClientState memory s) public pure returns (bytes32) {
        return keccak256(abi.encode(s.chainId, s.revisionNumber, s.trustLevel, s.trustingPeriod, s.maxClockDrift));
    }

    /// @notice Checks 11 to 15: the launch client and every component naming it are the deployment's own.
    function check(address admin, IIBCAdmin.Launch calldata launch) external view {
        IAdminViews a = IAdminViews(admin);
        address router = a.router();
        address ics20 = a.ics20();
        string memory id = launch.clientId;
        _check(keccak256(bytes(a.govClient())) == keccak256(bytes(id)), 11);
        address lc = address(IICS02Client(router).getClient(id));
        _check(lc == launch.lightClient && lc.code.length != 0 && lc.codehash == launch.lightClientCodeHash, 11);
        bytes memory cs = IGnoVerifierViews(lc).getClientState();
        Msgs.ClientState memory state = abi.decode(cs, (Msgs.ClientState));
        // the immutable parameters and the original checkpoint, never the current height or consensus state: a
        // verified update anyone relays advances those, and must not stop the launch; a frozen client must
        _check(keccak256(bytes(state.chainId)) == keccak256(bytes(a.gnoChainId())) && !state.isFrozen, 12);
        if (launch.clientParamsHash != bytes32(0)) _check(clientParamsHash(state) == launch.clientParamsHash, 12);
        if (launch.consensusStateHash != bytes32(0)) {
            _check(state.latestHeight >= launch.launchHeight, 12);
            Msgs.ConsensusState memory c = IGnoVerifierViews(lc).getConsensusState(launch.launchHeight);
            _check(keccak256(abi.encode(c)) == launch.consensusStateHash, 12);
        }
        IICS02ClientMsgs.CounterpartyInfo memory cp = IICS02Client(router).getCounterparty(id);
        _check(
            keccak256(bytes(cp.clientId)) == keccak256(bytes(launch.counterpartyClientId))
                && S.canonicalCounterparty(cp.clientId, cp.merklePrefix),
            13
        );
        address voucher = launch.ugnotVoucher;
        _check(
            IICS20Transfer(ics20).ibcERC20Contract(string.concat(ICS20Lib.DEFAULT_PORT_ID, "/", id, "/ugnot"))
                    == voucher && IVoucherBinding(voucher).ics20() == ics20,
            14
        );
        _check(
            IGnoICS20Controls(ics20).limits(id, voucher).set
                && IGnoICS20Controls(ics20).quarantineSeconds(id) == launch.quarantineSeconds,
            15
        );
    }

    function _check(bool ok, uint8 n) private pure {
        if (!ok) revert IIBCAdmin.SetupIncomplete(n);
    }
}
