// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {OracleBaseEIP712} from "./base/OracleBaseEIP712.sol";
import {IAgriCustodyV1} from "../interfaces/v1/IAgriCustodyV1.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @title CustodyOracle
/// @notice EIP-712 attestation oracle for custody/inventory (payloadHash commits custody root / warehouse lots, etc.).
/// @dev Implements IAgriCustodyV1 for custody freshness gating.
contract CustodyOracle is OracleBaseEIP712, IAgriCustodyV1 {
    constructor(address roleManager_)
        OracleBaseEIP712("uAgri Custody Oracle", "1", roleManager_, UAgriRoles.CUSTODY_ATTESTER_ROLE)
    {}

    function initialize(address roleManager_) external {
        _init(roleManager_, UAgriRoles.CUSTODY_ATTESTER_ROLE);
    }

    /// @inheritdoc IAgriCustodyV1
    function lastCustodyEpoch(bytes32 campaignId) external view returns (uint64) {
        return _latestEpoch[campaignId];
    }

    /// @inheritdoc IAgriCustodyV1
    function custodyValidUntil(bytes32 campaignId) public view returns (uint64) {
        uint64 e = _latestEpoch[campaignId];
        if (e == 0) return 0;
        return uint64(_validUntil[campaignId][e]);
    }

    /// @inheritdoc IAgriCustodyV1
    function isCustodyFresh(bytes32 campaignId) external view returns (bool) {
        uint64 e = _latestEpoch[campaignId];
        if (e == 0) return false;

        uint64 vu = uint64(_validUntil[campaignId][e]);
        if (vu == 0) return true; // 0 = no-expiry profile
        return uint64(block.timestamp) <= vu;
    }
}
