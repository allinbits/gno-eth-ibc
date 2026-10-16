// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

// The numbered check list follows gnolang/bridges (branch ethereum-draft),
// ethereum/bridge/contracts/src/admin/HlAdminExec.sol `checkSetup`. Copyright (C) 2026 NewTendermint, LLC. GNO Network
// General Public License: see contracts/licenses/.

import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import { UpgradeableBeacon } from "@openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

import { IICS02Client, IICS02ClientAccessControlled } from "@eureka/interfaces/IICS02Client.sol";
import { IICS26Router, IICS26RouterAccessControlled } from "@eureka/interfaces/IICS26Router.sol";
import { IICS20Transfer, IICS20TransferAccessControlled } from "@eureka/interfaces/IICS20Transfer.sol";
import { IPausable } from "@eureka/interfaces/IPausable.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { IIBCAdmin } from "../interfaces/IIBCAdmin.sol";
import { IGnoICS20Controls } from "../interfaces/IGnoICS20Controls.sol";

/// @notice The views of IBCAdmin the check list reads.
interface IIBCAdminViews {
    function router() external view returns (address);
    function accessManager() external view returns (address);
    function ics20() external view returns (address);
    function govClient() external view returns (string memory);
    function keys() external view returns (address[6] memory);
}

interface IGnoICS20Fork {
    function CONTROLS() external view returns (address);
}

/// @title `finishSetup`'s check list (ADR pr6375 E4, E11)
/// @notice Reads every authority and binding of a deployment back and reverts `SetupIncomplete(n)` at the first
/// that is not the deployment's:
///  1 IBCAdmin holds ADMIN_ROLE, with no execution delay;
///  2 the deployer holds none of the roles ADMIN, RELAYER, PAUSER, UNPAUSER, DELEGATE_SENDER, RATE_LIMITER,
///    ID_CUSTOMIZER, ERC20_CUSTOMIZER;
///  3 every one of these roles is administered by ADMIN_ROLE, with no grant delay;
///  4 the router's governed functions (custom ids: addIBCApp, addClient; migrateClient; upgradeToAndCall) are
///    ADMIN_ROLE's, and the router is open with no admin delay;
///  5 the relaying functions are the public's or RELAYER_ROLE's;
///  6 the transfer app's governed functions (setCustomERC20, upgrades, beacons and every control setter) are
///    ADMIN_ROLE's, pause and unpause PAUSER/UNPAUSER_ROLE's (granted to nobody: ADR §7.3), and the app is open with
///    no admin delay;
///  7 the router answers to the AccessManager, its `transfer` port is the transfer app and its `ibcgov` port IBCAdmin;
///  8 the epoch's client exists;
///  9 the transfer app answers to the AccessManager and the router, runs the fork (it serves CONTROLS), and its
///    beacons are its own;
/// 10 the transfer app's guardian keys are IBCAdmin's.
/// IBCAdmin adds 40 (its own record is the launch's). The AccessManager cannot list a role's members, so other
/// holders of a role are the audit tool's to find (its RoleGranted log).
contract IBCAdminSetupCheck {
    function check(address admin, address deployer) external view {
        IIBCAdminViews a = IIBCAdminViews(admin);
        address router = a.router();
        address ics20 = a.ics20();
        IAccessManager am = IAccessManager(a.accessManager());
        (bool isAdmin, uint32 delay) = am.hasRole(IBCRolesLib.ADMIN_ROLE, admin);
        _check(isAdmin && delay == 0, 1);
        uint64[8] memory roles = [
            IBCRolesLib.ADMIN_ROLE,
            IBCRolesLib.RELAYER_ROLE,
            IBCRolesLib.PAUSER_ROLE,
            IBCRolesLib.UNPAUSER_ROLE,
            IBCRolesLib.DELEGATE_SENDER_ROLE,
            IBCRolesLib.RATE_LIMITER_ROLE,
            IBCRolesLib.ID_CUSTOMIZER_ROLE,
            IBCRolesLib.ERC20_CUSTOMIZER_ROLE
        ];
        for (uint256 i = 0; i < roles.length; i++) {
            (bool has,) = am.hasRole(roles[i], deployer);
            _check(!has, 2);
            _check(am.getRoleAdmin(roles[i]) == IBCRolesLib.ADMIN_ROLE && am.getRoleGrantDelay(roles[i]) == 0, 3);
        }
        _checkRouter(am, router);
        _checkTransfer(am, ics20, router);
        _check(address(IICS26Router(router).getIBCApp(ICS20Lib.DEFAULT_PORT_ID)) == ics20, 7);
        _check(address(IICS26Router(router).getIBCApp("ibcgov")) == admin, 7);
        _check(IAccessManaged(router).authority() == address(am), 7);
        (bool ok,) = router.staticcall(abi.encodeCall(IICS02Client.getClient, (a.govClient())));
        _check(ok, 8);
        address[6] memory theirs = IGnoICS20Controls(ics20).guardianKeys();
        address[6] memory ours = a.keys();
        for (uint256 i = 0; i < 6; i++) {
            _check(theirs[i] == ours[i], 10);
        }
    }

    function _checkRouter(IAccessManager am, address router) private view {
        _check(!am.isTargetClosed(router) && am.getTargetAdminDelay(router) == 0, 4);
        bytes4[4] memory gov = [
            IICS26RouterAccessControlled.addIBCApp.selector,
            IICS02ClientAccessControlled.addClient.selector,
            IICS02ClientAccessControlled.migrateClient.selector,
            UUPSUpgradeable.upgradeToAndCall.selector
        ];
        for (uint256 i = 0; i < gov.length; i++) {
            _check(am.getTargetFunctionRole(router, gov[i]) == IBCRolesLib.ADMIN_ROLE, 4);
        }
        bytes4[] memory relay = IBCRolesLib.ics26RelayerSelectors();
        for (uint256 i = 0; i < relay.length; i++) {
            uint64 role = am.getTargetFunctionRole(router, relay[i]);
            _check(role == IBCRolesLib.PUBLIC_ROLE || role == IBCRolesLib.RELAYER_ROLE, 5);
        }
    }

    function _checkTransfer(IAccessManager am, address ics20, address router) private view {
        _check(!am.isTargetClosed(ics20) && am.getTargetAdminDelay(ics20) == 0, 6);
        bytes4[11] memory gov = [
            IICS20TransferAccessControlled.setCustomERC20.selector,
            IICS20TransferAccessControlled.upgradeEscrowTo.selector,
            IICS20TransferAccessControlled.upgradeIBCERC20To.selector,
            UUPSUpgradeable.upgradeToAndCall.selector,
            IGnoICS20Controls.initializeGno.selector,
            IGnoICS20Controls.setGuardianKeys.selector,
            IGnoICS20Controls.setLimits.selector,
            IGnoICS20Controls.setQuarantine.selector,
            IGnoICS20Controls.unpauseRoute.selector,
            IGnoICS20Controls.setRecoveryBlock.selector,
            IGnoICS20Controls.migrateRoute.selector
        ];
        for (uint256 i = 0; i < gov.length; i++) {
            _check(am.getTargetFunctionRole(ics20, gov[i]) == IBCRolesLib.ADMIN_ROLE, 6);
        }
        _check(am.getTargetFunctionRole(ics20, IPausable.pause.selector) == IBCRolesLib.PAUSER_ROLE, 6);
        _check(am.getTargetFunctionRole(ics20, IPausable.unpause.selector) == IBCRolesLib.UNPAUSER_ROLE, 6);
        _check(IAccessManaged(ics20).authority() == address(am) && IICS20Transfer(ics20).ics26() == router, 9);
        (bool ok,) = ics20.staticcall(abi.encodeCall(IGnoICS20Fork.CONTROLS, ()));
        _check(ok, 9);
        _check(UpgradeableBeacon(IICS20Transfer(ics20).getEscrowBeacon()).owner() == ics20, 9);
        _check(UpgradeableBeacon(IICS20Transfer(ics20).getIBCERC20Beacon()).owner() == ics20, 9);
    }

    function _check(bool ok, uint8 n) private pure {
        if (!ok) revert IIBCAdmin.SetupIncomplete(n);
    }
}
