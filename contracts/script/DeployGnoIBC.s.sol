// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { AccessManager } from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";

import { ICS26Router } from "@eureka/ICS26Router.sol";
import { ICS20Transfer } from "@eureka/ICS20Transfer.sol";
import { Escrow } from "@eureka/utils/Escrow.sol";
import { IBCERC20 } from "@eureka/utils/IBCERC20.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";

import { GnoLightClient } from "../src/GnoLightClient.sol";
import { GnoICS20Transfer } from "../src/GnoICS20Transfer.sol";
import { GnoICS20Controls } from "../src/transfer/GnoICS20Controls.sol";
import { GnoICS20Reconcile } from "../src/transfer/GnoICS20Reconcile.sol";
import { GnoICS20Evidence } from "../src/transfer/GnoICS20Evidence.sol";
import { IGnoICS20Controls, IGnoICS20ControlsTypes } from "../src/interfaces/IGnoICS20Controls.sol";
import { IIBCAdmin } from "../src/interfaces/IIBCAdmin.sol";
import { IBCAdmin } from "../src/admin/IBCAdmin.sol";
import { IBCAdminExec } from "../src/admin/IBCAdminExec.sol";
import { GnoDenoms } from "./GnoDenoms.sol";
import { IGnoLightClientMsgs as Msgs } from "../src/msgs/IGnoLightClientMsgs.sol";

/// @title Deploy IBC v2 on an EVM chain with a GnoLightClient tracking a gno.land chain, and its controls
/// @notice Deploys AccessManager, ICS26Router and GnoICS20Transfer (as the ICS20 proxy's first implementation: the
/// deployment is fresh, no packet predates the fork) behind ERC1967 proxies (as solidity-ibc-eureka v3.0.2's
/// E2ETestDeploy), initializes the fork's controls, registers it on port "transfer", deploys the GnoLightClient
/// from a trusted gno header and adds it with the gno side as counterparty, registers the ugnot voucher (6 decimals,
/// GnoVoucher) with its launch limits and the route's quarantine, deploys IBCAdmin (with its executor) on port "ibcgov"
/// over the same client, and hands it every authority: ADMIN_ROLE to IBCAdmin, the deployer's renounced. Last,
/// IBCAdmin.finishSetup reads every authority back and fails the deployment if one is not as it should be (ADR pr6375
/// E4, E11). The deployer never holds ID_CUSTOMIZER_ROLE or ERC20_CUSTOMIZER_ROLE: those functions are ADMIN_ROLE's.
/// @dev Environment:
///   DEPLOYER_PRIVATE_KEY        deployer key (required; never stored)
///   GNO_TRUST_FILE              JSON with "clientState" and "consensusState", each the ABI encoding of the
///                               GnoLightClient struct (written by `relayer trust`); default deployments/trust.json
///   GNO_COUNTERPARTY_CLIENT_ID  the gno-side Ethereum client id; default "ethereum-1"
///   RELAYER_ADDRESS             if set, only this address may relay; otherwise relaying is public
///   GUARDIANS                   4 comma-separated guardian addresses (seats 0-3); WATCH_KEYS: 2 watch keys (4-5).
///                               Required except on a local chain (chain id 31337), where development keys are used.
///   EXPECTED_LOCK               the ugnot lock expected on gno.land, in base units (required off a local chain): the
///                               launch day cap is min(100,000 GNOT, lock/10), the maximum per message
///                               min(25,000 GNOT, day cap), the refund cap the day cap (ADR §7.2, §9)
///   GNOT_MAX_PER_MESSAGE, GNOT_DAY_CAP, GNOT_REFUND_CAP  optional lower ugnot launch limits, in base units
///   QUARANTINE_SECONDS          the route's quarantine after a validator-set transition; default 7 days
///   RECOVERY_DELAY              the emergency recovery's delay; 0 (default) deploys it disabled (§7.12).
///   RECOVERY_THRESHOLD, RECOVERY_CANCEL_THRESHOLD, RECOVERY_SILENCE, RECOVERY_HOLD_PERIOD  its other settings
///                               (approval at least 3 of 4 guardians, cancellation at least 2)
///   DEPLOYMENTS_FILE            output JSON; default deployments/<chainid>.json
/// Run: forge script script/DeployGnoIBC.s.sol --rpc-url $ETH_RPC_URL --broadcast
contract DeployGnoIBC is Script {
    using stdJson for string;

    /// @notice The gno.land merkle prefix of the IBC core realm's packet state (see contracts/README.md).
    bytes internal constant GNO_STORE = "main";
    bytes internal constant GNO_KEY_PREFIX = "/pv/vm:gno.land/r/aib/ibc/core:";
    /// @notice IBCAdmin's port: `gov` in ADR §5.4, but eureka's router refuses custom port ids under 4 characters.
    string internal constant GOV_PORT = "ibcgov";
    uint256 internal constant GNOT = 1e6;

    struct Params {
        address deployer;
        address relayer;
        Msgs.ClientState clientState;
        Msgs.ConsensusState consensusState;
        /// A light client to add instead of deploying a GnoLightClient from the trust state (tests).
        address lightClient;
        string counterparty;
        address[4] guardians;
        address[2] watch;
        /// The ugnot lock expected on gno.land (base units): the launch limits derive from it (ADR §7.2, §9).
        uint256 expectedLock;
        IGnoICS20ControlsTypes.Limits gnotLimits;
        uint64 quarantineSeconds;
        /// Permit2 for `sendTransferWithPermit2` (zero: none, as eureka's E2E deploy).
        address permit2;
        IIBCAdmin.RecoveryConfig recovery;
    }

    struct Deployed {
        address accessManager;
        address ics26Router;
        address ics20Transfer;
        address ics20Implementation;
        address ics20Controls;
        address gnoLightClient;
        string clientId;
        address ugnotVoucher;
        address ibcAdmin;
        address ibcAdminExec;
    }

    function run() external returns (Deployed memory d) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        Params memory p = _params(vm.addr(pk));

        vm.startBroadcast(pk);
        d = _deploy(p);
        vm.stopBroadcast();

        string memory out =
            vm.envOr("DEPLOYMENTS_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        string memory j = "deployed";
        j.serialize("chainId", block.chainid);
        j.serialize("accessManager", d.accessManager);
        j.serialize("ics26Router", d.ics26Router);
        j.serialize("ics20Transfer", d.ics20Transfer);
        j.serialize("ics20Implementation", d.ics20Implementation);
        j.serialize("ics20Controls", d.ics20Controls);
        j.serialize("gnoLightClient", d.gnoLightClient);
        j.serialize("ugnotVoucher", d.ugnotVoucher);
        j.serialize("ibcAdmin", d.ibcAdmin);
        j.serialize("ibcAdminExec", d.ibcAdminExec);
        j.serialize("gnoChainId", p.clientState.chainId);
        j.serialize("counterpartyClientId", p.counterparty);
        j = j.serialize("clientId", d.clientId);
        vm.writeJson(j, out);
    }

    function _params(address deployer) internal view returns (Params memory p) {
        string memory trust = vm.readFile(vm.envOr("GNO_TRUST_FILE", string("deployments/trust.json")));
        p.deployer = deployer;
        p.relayer = vm.envOr("RELAYER_ADDRESS", address(0));
        p.clientState = abi.decode(trust.readBytes(".clientState"), (Msgs.ClientState));
        p.consensusState = abi.decode(trust.readBytes(".consensusState"), (Msgs.ConsensusState));
        p.counterparty = vm.envOr("GNO_COUNTERPARTY_CLIENT_ID", string("ethereum-1"));
        address[] memory none = new address[](0);
        address[] memory g = vm.envOr("GUARDIANS", ",", none);
        address[] memory w = vm.envOr("WATCH_KEYS", ",", none);
        if (g.length == 0 && w.length == 0) {
            require(block.chainid == 31_337, "GUARDIANS and WATCH_KEYS are required off a local chain");
            for (uint256 i = 0; i < 4; i++) {
                p.guardians[i] = vm.addr(uint256(keccak256(abi.encode("gno-eth-ibc local guardian", i))));
            }
            for (uint256 i = 0; i < 2; i++) {
                p.watch[i] = vm.addr(uint256(keccak256(abi.encode("gno-eth-ibc local watch key", i))));
            }
        } else {
            require(g.length == 4 && w.length == 2, "GUARDIANS needs 4 addresses, WATCH_KEYS 2");
            p.guardians = [g[0], g[1], g[2], g[3]];
            p.watch = [w[0], w[1]];
        }
        // the expected lock is required off a local chain: the launch caps derive from it
        p.expectedLock =
            block.chainid == 31_337 ? vm.envOr("EXPECTED_LOCK", 1_000_000 * GNOT) : vm.envUint("EXPECTED_LOCK");
        p.gnotLimits = _launchLimits(
            p.expectedLock,
            vm.envOr("GNOT_MAX_PER_MESSAGE", uint256(0)),
            vm.envOr("GNOT_DAY_CAP", uint256(0)),
            vm.envOr("GNOT_REFUND_CAP", uint256(0))
        );
        p.quarantineSeconds = _u64(vm.envOr("QUARANTINE_SECONDS", uint256(7 days)), "QUARANTINE_SECONDS");
        p.recovery = IIBCAdmin.RecoveryConfig({
            delay: _u64(vm.envOr("RECOVERY_DELAY", uint256(0)), "RECOVERY_DELAY"),
            threshold: _u8(vm.envOr("RECOVERY_THRESHOLD", uint256(3)), "RECOVERY_THRESHOLD"),
            cancelThreshold: _u8(vm.envOr("RECOVERY_CANCEL_THRESHOLD", uint256(3)), "RECOVERY_CANCEL_THRESHOLD"),
            silence: _u64(vm.envOr("RECOVERY_SILENCE", uint256(30 days)), "RECOVERY_SILENCE"),
            holdPeriod: _u64(vm.envOr("RECOVERY_HOLD_PERIOD", uint256(14 days)), "RECOVERY_HOLD_PERIOD")
        });
    }

    /// @notice The ugnot launch limits of ADR §9 for an expected lock: day cap min(100,000 GNOT, lock / 10), maximum
    /// per message min(25,000 GNOT, day cap), refund cap the day cap. An override (non-zero) may only lower them.
    function _launchLimits(
        uint256 expectedLock,
        uint256 maxOverride,
        uint256 dayOverride,
        uint256 refundOverride
    )
        internal
        pure
        returns (IGnoICS20ControlsTypes.Limits memory l)
    {
        require(expectedLock != 0, "EXPECTED_LOCK is required");
        uint256 dayCap = _min(100_000 * GNOT, expectedLock / 10);
        uint256 maxPerMessage = _min(25_000 * GNOT, dayCap);
        require(
            dayOverride <= dayCap && maxOverride <= maxPerMessage && refundOverride <= dayCap, "overrides only lower"
        );
        l.dayCap = dayOverride != 0 ? dayOverride : dayCap;
        l.maxPerMessage = _min(maxOverride != 0 ? maxOverride : maxPerMessage, l.dayCap);
        l.refundCap = refundOverride != 0 ? refundOverride : l.dayCap;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _u64(uint256 v, string memory name) internal pure returns (uint64) {
        require(v <= type(uint64).max, string.concat(name, " out of range"));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(v);
    }

    function _u8(uint256 v, string memory name) internal pure returns (uint8) {
        require(v <= type(uint8).max, string.concat(name, " out of range"));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(v);
    }

    function _deploy(Params memory p) internal returns (Deployed memory d) {
        // the launch limits never exceed what the expected lock allows (ADR §7.2, §9)
        IGnoICS20ControlsTypes.Limits memory most = _launchLimits(p.expectedLock, 0, 0, 0);
        require(
            p.gnotLimits.dayCap <= most.dayCap && p.gnotLimits.maxPerMessage <= most.maxPerMessage
                && p.gnotLimits.maxPerMessage <= p.gnotLimits.dayCap && p.gnotLimits.refundCap <= most.dayCap,
            "launch limits above the expected lock's"
        );
        AccessManager am = new AccessManager(p.deployer);
        d.accessManager = address(am);
        d.ics26Router = address(
            new ERC1967Proxy(address(new ICS26Router()), abi.encodeCall(ICS26Router.initialize, (address(am))))
        );
        // a fresh deployment: the fork is the proxy's first implementation (no packet predates it)
        d.ics20Controls = address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))));
        d.ics20Implementation = address(new GnoICS20Transfer(d.ics20Controls));
        d.ics20Transfer = address(
            new ERC1967Proxy(
                d.ics20Implementation,
                abi.encodeCall(
                    ICS20Transfer.initialize,
                    (d.ics26Router, address(new Escrow()), address(new IBCERC20()), p.permit2, address(am))
                )
            )
        );
        _setRoles(am, d, p.relayer);
        address[6] memory keys =
            [p.guardians[0], p.guardians[1], p.guardians[2], p.guardians[3], p.watch[0], p.watch[1]];
        IGnoICS20Controls(d.ics20Transfer).initializeGno(keys);
        ICS26Router(d.ics26Router).addIBCApp(ICS20Lib.DEFAULT_PORT_ID, d.ics20Transfer);

        d.gnoLightClient =
            p.lightClient != address(0) ? p.lightClient : address(new GnoLightClient(p.clientState, p.consensusState));
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = GNO_STORE;
        prefix[1] = GNO_KEY_PREFIX;
        d.clientId = ICS26Router(d.ics26Router)
            .addClient(
                IICS02ClientMsgs.CounterpartyInfo({ clientId: p.counterparty, merklePrefix: prefix }), d.gnoLightClient
            );

        d.ugnotVoucher = GnoDenoms.register(d.ics20Transfer, d.clientId, "ugnot", "Gno.land", "GNOT", 6);
        IGnoICS20Controls(d.ics20Transfer).setLimits(d.clientId, d.ugnotVoucher, p.gnotLimits);
        IGnoICS20Controls(d.ics20Transfer).setQuarantine(d.clientId, p.quarantineSeconds);

        d.ibcAdminExec = address(new IBCAdminExec(d.ics26Router, d.accessManager, d.ics20Transfer));
        d.ibcAdmin = address(
            new IBCAdmin(
                IBCAdmin.Config({
                    router: d.ics26Router,
                    accessManager: d.accessManager,
                    ics20: d.ics20Transfer,
                    exec: d.ibcAdminExec,
                    govClientId: d.clientId,
                    gnoChainId: p.clientState.chainId,
                    seats: p.guardians,
                    watch: p.watch,
                    recovery: p.recovery
                })
            )
        );
        ICS26Router(d.ics26Router).addIBCApp(GOV_PORT, d.ibcAdmin);

        // the hand-over: IBCAdmin takes ADMIN_ROLE, the deployer renounces it (it holds no other role)
        am.grantRole(IBCRolesLib.ADMIN_ROLE, d.ibcAdmin, 0);
        am.renounceRole(IBCRolesLib.ADMIN_ROLE, p.deployer);
        IBCAdmin(d.ibcAdmin).finishSetup();
    }

    /// @notice The functions' roles: every governed function is ADMIN_ROLE's (IBCAdmin's after the hand-over),
    /// relaying is public or RELAYER_ROLE's, pause/unpause and the delegate sender keep eureka's roles, granted to
    /// nobody (a pause would block acknowledgements and refunds: ADR §7.3).
    function _setRoles(AccessManager am, Deployed memory d, address relayer) internal {
        am.setTargetFunctionRole(d.ics26Router, IBCRolesLib.ics26IdCustomizerSelectors(), IBCRolesLib.ADMIN_ROLE);
        am.setTargetFunctionRole(
            d.ics26Router,
            IBCRolesLib.ics26RelayerSelectors(),
            relayer == address(0) ? IBCRolesLib.PUBLIC_ROLE : IBCRolesLib.RELAYER_ROLE
        );
        am.setTargetFunctionRole(d.ics20Transfer, IBCRolesLib.pauserSelectors(), IBCRolesLib.PAUSER_ROLE);
        am.setTargetFunctionRole(d.ics20Transfer, IBCRolesLib.unpauserSelectors(), IBCRolesLib.UNPAUSER_ROLE);
        am.setTargetFunctionRole(d.ics20Transfer, IBCRolesLib.erc20CustomizerSelectors(), IBCRolesLib.ADMIN_ROLE);
        am.setTargetFunctionRole(
            d.ics20Transfer, IBCRolesLib.delegateSenderSelectors(), IBCRolesLib.DELEGATE_SENDER_ROLE
        );
        am.setTargetFunctionRole(d.ics26Router, IBCRolesLib.ics26ClientMigrationSelectors(), IBCRolesLib.ADMIN_ROLE);
        am.setTargetFunctionRole(d.ics20Transfer, IBCRolesLib.ics20BeaconUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE);
        am.setTargetFunctionRole(d.ics20Transfer, IBCRolesLib.uupsUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE);
        am.setTargetFunctionRole(d.ics26Router, IBCRolesLib.uupsUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE);
        if (relayer != address(0)) am.grantRole(IBCRolesLib.RELAYER_ROLE, relayer, 0);
    }
}
