// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {OracleBaseEIP712} from "./base/OracleBaseEIP712.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @title HarvestOracle
/// @notice EIP-712 attestation oracle for harvest evidence (quantity/quality/lots committed in payloadHash off-chain).
contract HarvestOracle is OracleBaseEIP712 {
    constructor(address roleManager_)
        OracleBaseEIP712("uAgri Harvest Oracle", "1", roleManager_, UAgriRoles.ORACLE_UPDATER_ROLE)
    {}

    /// @notice Initializer for clones (role is fixed for this oracle).
    function initialize(address roleManager_) external {
        _init(roleManager_, UAgriRoles.ORACLE_UPDATER_ROLE);
    }
}
