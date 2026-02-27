// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriDisasterV1} from "./IAgriDisasterV1.sol";

/// @notice Administrative disaster interface (TTL fast-path + dual-control confirmation).
interface IAgriDisasterAdminV1 is IAgriDisasterV1 {
    struct DisasterState {
        uint256 flags;      // campaign flag bitset (see UAgriFlags)
        uint8   severity;   // 0..4
        uint64  expiresAt;  // 0 = no TTL / confirmed; otherwise unix ts
        bytes32 hazardCode; // bytes32 ASCII padded (see UAgriHazards baseline)
        bytes32 reasonHash; // off-chain evidence pack hash / report hash
        bool    confirmed;  // true if governance-confirmed
    }

    event DisasterDeclared(
        bytes32 indexed campaignId,
        bytes32 indexed hazardCode,
        uint8 severity,
        uint256 flags,
        uint64 expiresAt,
        bytes32 reasonHash
    );

    event DisasterConfirmed(
        bytes32 indexed campaignId,
        uint8 severity,
        uint256 flags
    );

    event DisasterCleared(bytes32 indexed campaignId);

    /// @notice View full state (implementations MUST NOT revert for view paths where practical).
    function getDisaster(bytes32 campaignId) external view returns (DisasterState memory);

    /// @notice TTL fast-path declaration (operationally quick).
    /// @param ttlSeconds 0 MAY mean "no TTL" only if caller is governance; otherwise SHOULD require TTL.
    function declareDisaster(
        bytes32 campaignId,
        bytes32 hazardCode,
        uint8 severity,
        bytes32 reasonHash,
        uint64 ttlSeconds
    ) external;

    /// @notice Dual-control confirmation/escalation (multisig/timelock in institutional profiles).
    function confirmDisaster(
        bytes32 campaignId,
        uint256 flags,
        uint8 severity
    ) external;

    /// @notice Clears disaster state (governance action).
    function clearDisaster(bytes32 campaignId) external;
}
