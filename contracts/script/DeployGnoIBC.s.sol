// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { AccessManager } from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ICS26Router } from "@eureka/ICS26Router.sol";
import { ICS20Transfer } from "@eureka/ICS20Transfer.sol";
import { Escrow } from "@eureka/utils/Escrow.sol";
import { IBCERC20 } from "@eureka/utils/IBCERC20.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";

import { GnoLightClient } from "../src/GnoLightClient.sol";
import { GnoDenoms } from "./GnoDenoms.sol";
import { IGnoLightClientMsgs as Msgs } from "../src/msgs/IGnoLightClientMsgs.sol";

/// @title Deploy IBC v2 on an EVM chain with a GnoLightClient tracking a gno.land chain
/// @notice Deploys, in the order and with the roles of solidity-ibc-eureka v3.0.2's E2ETestDeploy:
/// AccessManager, ICS26Router and ICS20Transfer behind ERC1967 proxies (ICS20Transfer creating its Escrow and
/// IBCERC20 beacons), registers ICS20 on port "transfer", then deploys GnoLightClient from a trusted gno header
/// and adds it to the router with the gno side as counterparty. Last, it registers the voucher of ugnot (6
/// decimals, see GnoVoucher); other gno.land denoms are registered with RegisterGnoDenom.s.sol.
/// @dev Environment:
///   DEPLOYER_PRIVATE_KEY        deployer key (required; never stored)
///   GNO_TRUST_FILE              JSON with "clientState" and "consensusState", each the ABI encoding of the
///                               GnoLightClient struct (written by `relayer trust`); default deployments/trust.json
///   GNO_COUNTERPARTY_CLIENT_ID  the gno-side Ethereum client id; default "ethereum-1"
///   RELAYER_ADDRESS             if set, only this address may relay; otherwise relaying is public
///   DEPLOYMENTS_FILE            output JSON; default deployments/<chainid>.json
/// Run: forge script script/DeployGnoIBC.s.sol --rpc-url $ETH_RPC_URL --broadcast
contract DeployGnoIBC is Script {
    using stdJson for string;

    /// @notice The gno.land merkle prefix of the IBC core realm's packet state (see contracts/README.md).
    bytes internal constant GNO_STORE = "main";
    bytes internal constant GNO_KEY_PREFIX = "/pv/vm:gno.land/r/aib/ibc/core:";

    struct Deployed {
        address accessManager;
        address ics26Router;
        address ics20Transfer;
        address gnoLightClient;
        string clientId;
        address ugnotVoucher;
    }

    function run() external returns (Deployed memory d) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory trust = vm.readFile(vm.envOr("GNO_TRUST_FILE", string("deployments/trust.json")));
        Msgs.ClientState memory cs = abi.decode(trust.readBytes(".clientState"), (Msgs.ClientState));
        Msgs.ConsensusState memory cons = abi.decode(trust.readBytes(".consensusState"), (Msgs.ConsensusState));
        string memory counterparty = vm.envOr("GNO_COUNTERPARTY_CLIENT_ID", string("ethereum-1"));
        address relayer = vm.envOr("RELAYER_ADDRESS", address(0));

        vm.startBroadcast(pk);
        d = _deploy(deployer, relayer, cs, cons, counterparty);
        vm.stopBroadcast();

        string memory out =
            vm.envOr("DEPLOYMENTS_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        string memory j = "deployed";
        j.serialize("chainId", block.chainid);
        j.serialize("accessManager", d.accessManager);
        j.serialize("ics26Router", d.ics26Router);
        j.serialize("ics20Transfer", d.ics20Transfer);
        j.serialize("gnoLightClient", d.gnoLightClient);
        j.serialize("ugnotVoucher", d.ugnotVoucher);
        j.serialize("gnoChainId", cs.chainId);
        j.serialize("counterpartyClientId", counterparty);
        j = j.serialize("clientId", d.clientId);
        vm.writeJson(j, out);
    }

    function _deploy(
        address deployer,
        address relayer,
        Msgs.ClientState memory cs,
        Msgs.ConsensusState memory cons,
        string memory counterparty
    )
        internal
        returns (Deployed memory d)
    {
        AccessManager am = new AccessManager(deployer);
        d.accessManager = address(am);
        d.ics26Router = address(
            new ERC1967Proxy(address(new ICS26Router()), abi.encodeCall(ICS26Router.initialize, (address(am))))
        );
        d.ics20Transfer = address(
            new ERC1967Proxy(
                address(new ICS20Transfer()),
                abi.encodeCall(
                    ICS20Transfer.initialize,
                    (d.ics26Router, address(new Escrow()), address(new IBCERC20()), address(0), address(am))
                )
            )
        );

        // roles, as in eureka's DeployAccessManagerWithRoles
        am.setTargetFunctionRole(
            d.ics26Router, IBCRolesLib.ics26IdCustomizerSelectors(), IBCRolesLib.ID_CUSTOMIZER_ROLE
        );
        am.setTargetFunctionRole(
            d.ics26Router,
            IBCRolesLib.ics26RelayerSelectors(),
            relayer == address(0) ? IBCRolesLib.PUBLIC_ROLE : IBCRolesLib.RELAYER_ROLE
        );
        am.setTargetFunctionRole(d.ics20Transfer, IBCRolesLib.pauserSelectors(), IBCRolesLib.PAUSER_ROLE);
        am.setTargetFunctionRole(d.ics20Transfer, IBCRolesLib.unpauserSelectors(), IBCRolesLib.UNPAUSER_ROLE);
        am.setTargetFunctionRole(
            d.ics20Transfer, IBCRolesLib.erc20CustomizerSelectors(), IBCRolesLib.ERC20_CUSTOMIZER_ROLE
        );
        am.setTargetFunctionRole(
            d.ics20Transfer, IBCRolesLib.delegateSenderSelectors(), IBCRolesLib.DELEGATE_SENDER_ROLE
        );
        am.setTargetFunctionRole(d.ics26Router, IBCRolesLib.ics26ClientMigrationSelectors(), IBCRolesLib.ADMIN_ROLE);
        am.setTargetFunctionRole(d.ics20Transfer, IBCRolesLib.ics20BeaconUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE);
        am.setTargetFunctionRole(d.ics20Transfer, IBCRolesLib.uupsUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE);
        am.setTargetFunctionRole(d.ics26Router, IBCRolesLib.uupsUpgradeSelectors(), IBCRolesLib.ADMIN_ROLE);
        if (relayer != address(0)) am.grantRole(IBCRolesLib.RELAYER_ROLE, relayer, 0);
        am.grantRole(IBCRolesLib.ID_CUSTOMIZER_ROLE, deployer, 0);
        am.grantRole(IBCRolesLib.ERC20_CUSTOMIZER_ROLE, deployer, 0);

        ICS26Router(d.ics26Router).addIBCApp(ICS20Lib.DEFAULT_PORT_ID, d.ics20Transfer);

        d.gnoLightClient = address(new GnoLightClient(cs, cons));
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = GNO_STORE;
        prefix[1] = GNO_KEY_PREFIX;
        d.clientId = ICS26Router(d.ics26Router)
            .addClient(
                IICS02ClientMsgs.CounterpartyInfo({ clientId: counterparty, merklePrefix: prefix }), d.gnoLightClient
            );

        d.ugnotVoucher = GnoDenoms.register(d.ics20Transfer, d.clientId, "ugnot", "Gno.land", "GNOT", 6);
    }
}
