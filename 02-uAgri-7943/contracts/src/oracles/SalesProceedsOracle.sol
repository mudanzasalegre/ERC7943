// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {OracleBaseEIP712} from "./base/OracleBaseEIP712.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @title SalesProceedsOracle
/// @notice EIP-712 attestation oracle for sales/proceeds evidence (amounts/lots/settlements committed in payloadHash off-chain).
contract SalesProceedsOracle is OracleBaseEIP712 {
    constructor(address roleManager_)
        OracleBaseEIP712("uAgri Sales/Proceeds Oracle", "1", roleManager_, UAgriRoles.ORACLE_UPDATER_ROLE)
    {}

    function initialize(address roleManager_) external {
        _init(roleManager_, UAgriRoles.ORACLE_UPDATER_ROLE);
    }
}
