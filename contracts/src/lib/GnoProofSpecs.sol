// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICS23 } from "./ICS23.sol";

/// @title ICS23 proof specs of gno.land's state
library GnoProofSpecs {
    /// @notice tm2/pkg/bptree/proof_spec.go BptreeSpec, used by the "main" store (ProofOp "ics23:bptree").
    /// EmptyChild is bptree's sentinelHash = sha256(0x02) (tm2/pkg/bptree/const.go).
    function bptreeSpec() internal pure returns (ICS23.ProofSpec memory spec) {
        uint256[] memory order = new uint256[](2);
        order[1] = 1;
        spec = ICS23.ProofSpec({
            leafSpec: ICS23.LeafSpec({
                hash: ICS23.HashOp.SHA256,
                prehashKey: ICS23.HashOp.NO_HASH,
                prehashValue: ICS23.HashOp.SHA256,
                length: ICS23.LengthOp.VAR_PROTO,
                prefix: hex"00"
            }),
            innerSpec: ICS23.InnerSpec({
                childOrder: order,
                childSize: 32,
                minPrefixLength: 1,
                maxPrefixLength: 1,
                emptyChild: abi.encodePacked(sha256(hex"02")),
                hash: ICS23.HashOp.SHA256
            }),
            maxDepth: 60,
            minDepth: 5,
            prehashKeyBeforeComparison: false
        });
    }

    /// @notice ics23 TendermintSpec: the simple Merkle map over store roots that rootmulti commits to
    /// (ProofOp "ics23:simple", tm2/pkg/store/types/ics23.go).
    function tendermintSpec() internal pure returns (ICS23.ProofSpec memory spec) {
        uint256[] memory order = new uint256[](2);
        order[1] = 1;
        spec = ICS23.ProofSpec({
            leafSpec: ICS23.LeafSpec({
                hash: ICS23.HashOp.SHA256,
                prehashKey: ICS23.HashOp.NO_HASH,
                prehashValue: ICS23.HashOp.SHA256,
                length: ICS23.LengthOp.VAR_PROTO,
                prefix: hex"00"
            }),
            innerSpec: ICS23.InnerSpec({
                childOrder: order,
                childSize: 32,
                minPrefixLength: 1,
                maxPrefixLength: 1,
                emptyChild: "",
                hash: ICS23.HashOp.SHA256
            }),
            maxDepth: 0,
            minDepth: 0,
            prehashKeyBeforeComparison: false
        });
    }
}
