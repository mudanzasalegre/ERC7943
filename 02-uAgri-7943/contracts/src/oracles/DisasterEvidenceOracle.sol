// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {OracleBaseEIP712} from "./base/OracleBaseEIP712.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @title DisasterEvidenceOracle
/// @notice EIP-712 attestation oracle for disaster evidence (severity/region proofs committed in payloadHash off-chain).
contract DisasterEvidenceOracle is OracleBaseEIP712 {
    constructor(address roleManager_)
        OracleBaseEIP712("uAgri Disaster Evidence Oracle", "1", roleManager_, UAgriRoles.ORACLE_UPDATER_ROLE)
    {}

    function initialize(address roleManager_) external {
        _init(roleManager_, UAgriRoles.ORACLE_UPDATER_ROLE);
    }
}
