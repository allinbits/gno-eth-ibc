// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ICS26Router } from "@eureka/ICS26Router.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";

/// @title The router and its launch client, in one transaction (ADR pr6375 E8, E11)
/// @notice Deploys the ICS26 router proxy and registers the launch Gno client in its constructor, so no transaction
/// can come between them: the router's first client id (`client-0`, the one gno.land's counterparty and every later
/// deployment step name) is the launch client's. eureka's `addClient(counterparty, client)` is permissionless, so a
/// router deployed in one transaction and given its client in another could have that id taken in between. The
/// launcher holds no role: the generated-id overload needs none.
contract RouterLauncher {
    address public immutable router;
    string public clientId;

    constructor(
        address routerImplementation,
        address accessManager,
        IICS02ClientMsgs.CounterpartyInfo memory counterparty,
        address lightClient
    ) {
        address r =
            address(new ERC1967Proxy(routerImplementation, abi.encodeCall(ICS26Router.initialize, (accessManager))));
        clientId = ICS26Router(r).addClient(counterparty, lightClient);
        router = r;
    }
}
