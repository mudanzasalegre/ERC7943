// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {RoleManager} from "../access/RoleManager.sol";
import {IAgriDisasterV1} from "../interfaces/v1/IAgriDisasterV1.sol";
import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriFlags} from "../interfaces/constants/UAgriFlags.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @title EmergencyPause
/// @notice Emergency pause controller with granular pause flags (Standard-Grade).
/// @dev
///  - Implements IAgriDisasterV1 so core contracts can read campaignFlags/isRestricted/isHardFrozen
///    via a single stable view interface.
///  - **Views MUST NOT revert** (they don't). When the module is *bound* to a campaignId, a mismatch
///    is treated as **fail-closed** (returns ALL_PAUSE_FLAGS / true).
///  - Pause bits are **normative** and defined in {UAgriFlags}:
///      PAUSE_TRANSFERS, PAUSE_FUNDING, PAUSE_REDEMPTIONS, PAUSE_CLAIMS, PAUSE_ORACLES
///  - Intended operator:
///      GUARDIAN_ROLE (plus DEFAULT_ADMIN_ROLE / GOVERNANCE_ROLE as override).
contract EmergencyPause is IAgriDisasterV1 {
    // ------------------------------- Errors ---------------------------------

    error EmergencyPause__AlreadyInitialized();
    error EmergencyPause__InvalidAddress();
    error EmergencyPause__InvalidFlags(uint256 provided);

    // ------------------------------- Events ---------------------------------

    event Initialized(address indexed roleManager, bytes32 indexed campaignId, uint256 initialFlags, address indexed caller);
    event PauseFlagsUpdated(bytes32 indexed campaignId, uint256 oldFlags, uint256 newFlags, address indexed caller);
    event PauseFlagSet(bytes32 indexed campaignId, uint256 indexed flag, bool enabled, address indexed caller);

    // ------------------------------ Constants -------------------------------

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    uint256 internal constant ALL_PAUSE_FLAGS =
        UAgriFlags.PAUSE_TRANSFERS |
        UAgriFlags.PAUSE_FUNDING |
        UAgriFlags.PAUSE_REDEMPTIONS |
        UAgriFlags.PAUSE_CLAIMS |
        UAgriFlags.PAUSE_ORACLES;

    // ------------------------------- Storage --------------------------------

    RoleManager public roleManager;

    /// @notice Optional binding. If non-zero, views are intended to be queried with this campaignId.
    /// @dev Stored (not immutable) to support clone/proxy init flows.
    bytes32 public immutableCampaignId;

    uint256 private _flags;
    bool private _initialized;

    // --------------------------- Initialization -----------------------------

    /// @dev Constructor deployment (recommended for non-clone deployments).
    constructor(address roleManager_, bytes32 campaignId_, uint256 initialFlags) {
        immutableCampaignId = campaignId_;
        _init(roleManager_, initialFlags);
    }

    /// @notice Initializer for clone/proxy patterns (call once).
    /// @dev Uses the already-stored immutableCampaignId (typically 0 for clones).
    function initialize(address roleManager_, uint256 initialFlags) external {
        _init(roleManager_, initialFlags);
    }

    /// @notice Initializer for clone/proxy patterns with campaign binding.
    /// @dev Call once. Useful when constructor is not executed (EIP-1167 clones).
    function initializeWithCampaign(address roleManager_, bytes32 campaignId_, uint256 initialFlags) external {
        if (_initialized) revert EmergencyPause__AlreadyInitialized();
        immutableCampaignId = campaignId_;
        _init(roleManager_, initialFlags);
    }

    function _init(address roleManager_, uint256 initialFlags) internal {
        if (_initialized) revert EmergencyPause__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert EmergencyPause__InvalidAddress();
        roleManager = RoleManager(roleManager_);

        _validateFlags(initialFlags);
        _flags = initialFlags;

        emit Initialized(roleManager_, immutableCampaignId, initialFlags, msg.sender);
        emit PauseFlagsUpdated(immutableCampaignId, 0, initialFlags, msg.sender);
    }

    // -------------------------------- Views ---------------------------------

    /// @inheritdoc IAgriDisasterV1
    function campaignFlags(bytes32 campaignId) external view returns (uint256) {
        if (_isCampaignMismatch(campaignId)) return ALL_PAUSE_FLAGS; // fail-closed
        return _flags;
    }

    /// @inheritdoc IAgriDisasterV1
    function isRestricted(bytes32 campaignId) external view returns (bool) {
        if (_isCampaignMismatch(campaignId)) return true; // fail-closed
        uint256 f = _flags;
        // "Restricted" => any non-transfer pause (operational limitations).
        return (f & (UAgriFlags.PAUSE_FUNDING | UAgriFlags.PAUSE_REDEMPTIONS | UAgriFlags.PAUSE_CLAIMS | UAgriFlags.PAUSE_ORACLES)) != 0;
    }

    /// @inheritdoc IAgriDisasterV1
    function isHardFrozen(bytes32 campaignId) external view returns (bool) {
        if (_isCampaignMismatch(campaignId)) return true; // fail-closed
        // "Hard frozen" => transfers paused.
        return (_flags & UAgriFlags.PAUSE_TRANSFERS) != 0;
    }

    /// @notice Convenience: returns current flags without requiring campaignId (UI helper).
    function flags() external view returns (uint256) {
        return _flags;
    }

    function transfersPaused() external view returns (bool) {
        return (_flags & UAgriFlags.PAUSE_TRANSFERS) != 0;
    }

    function fundingPaused() external view returns (bool) {
        return (_flags & UAgriFlags.PAUSE_FUNDING) != 0;
    }

    function redemptionsPaused() external view returns (bool) {
        return (_flags & UAgriFlags.PAUSE_REDEMPTIONS) != 0;
    }

    function claimsPaused() external view returns (bool) {
        return (_flags & UAgriFlags.PAUSE_CLAIMS) != 0;
    }

    function oraclesPaused() external view returns (bool) {
        return (_flags & UAgriFlags.PAUSE_ORACLES) != 0;
    }

    // ----------------------------- Admin ops --------------------------------

    /// @notice Set entire flags word (only known pause bits allowed).
    function setFlags(uint256 newFlags) external {
        _requireGuardianOrGovernance();
        _validateFlags(newFlags);

        uint256 old = _flags;
        if (old == newFlags) return;

        _flags = newFlags;
        emit PauseFlagsUpdated(immutableCampaignId, old, newFlags, msg.sender);
    }

    /// @notice Enable/disable specific flag bits (mask must be subset of known pause flags).
    function setPaused(uint256 mask, bool enabled) external {
        _requireGuardianOrGovernance();
        _validateFlags(mask);

        uint256 old = _flags;
        uint256 neu = enabled ? (old | mask) : (old & ~mask);

        if (old == neu) return;

        _flags = neu;

        // 5 bits only — acceptable for UX/audit.
        _emitPerFlag(mask, enabled);
        emit PauseFlagsUpdated(immutableCampaignId, old, neu, msg.sender);
    }

    // ---- Convenience single-flag setters (normative names) ----

    function pauseTransfers(bool enabled) external {
        _setSingle(UAgriFlags.PAUSE_TRANSFERS, enabled);
    }

    function pauseFunding(bool enabled) external {
        _setSingle(UAgriFlags.PAUSE_FUNDING, enabled);
    }

    function pauseRedemptions(bool enabled) external {
        _setSingle(UAgriFlags.PAUSE_REDEMPTIONS, enabled);
    }

    function pauseClaims(bool enabled) external {
        _setSingle(UAgriFlags.PAUSE_CLAIMS, enabled);
    }

    /// @notice Pause oracle updates/actions.
    /// @dev Name matches RECETA MAESTRA wording ("pauseOracleUpdates").
    function pauseOracleUpdates(bool enabled) external {
        _setSingle(UAgriFlags.PAUSE_ORACLES, enabled);
    }

    /// @notice Backwards-compatible alias.
    function pauseOracles(bool enabled) external {
        _setSingle(UAgriFlags.PAUSE_ORACLES, enabled);
    }

    function _setSingle(uint256 flag, bool enabled) internal {
        _requireGuardianOrGovernance();
        _validateFlags(flag);

        uint256 old = _flags;
        uint256 neu = enabled ? (old | flag) : (old & ~flag);
        if (old == neu) return;

        _flags = neu;
        emit PauseFlagSet(immutableCampaignId, flag, enabled, msg.sender);
        emit PauseFlagsUpdated(immutableCampaignId, old, neu, msg.sender);
    }

    // ----------------------------- Internals --------------------------------

    function _isCampaignMismatch(bytes32 campaignId) internal view returns (bool) {
        bytes32 bound = immutableCampaignId;
        return (bound != bytes32(0) && campaignId != bound);
    }

    function _requireGuardianOrGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GUARDIAN_ROLE, caller)
        ) {
            return;
        }

        revert UAgriErrors.UAgri__Unauthorized();
    }

    function _validateFlags(uint256 flags_) internal pure {
        if ((flags_ & ~ALL_PAUSE_FLAGS) != 0) revert EmergencyPause__InvalidFlags(flags_);
    }

    function _emitPerFlag(uint256 mask, bool enabled) internal {
        bytes32 cid = immutableCampaignId;

        // Unrolled for gas predictability (5 bits only).
        if ((mask & UAgriFlags.PAUSE_TRANSFERS) != 0) emit PauseFlagSet(cid, UAgriFlags.PAUSE_TRANSFERS, enabled, msg.sender);
        if ((mask & UAgriFlags.PAUSE_FUNDING) != 0) emit PauseFlagSet(cid, UAgriFlags.PAUSE_FUNDING, enabled, msg.sender);
        if ((mask & UAgriFlags.PAUSE_REDEMPTIONS) != 0) emit PauseFlagSet(cid, UAgriFlags.PAUSE_REDEMPTIONS, enabled, msg.sender);
        if ((mask & UAgriFlags.PAUSE_CLAIMS) != 0) emit PauseFlagSet(cid, UAgriFlags.PAUSE_CLAIMS, enabled, msg.sender);
        if ((mask & UAgriFlags.PAUSE_ORACLES) != 0) emit PauseFlagSet(cid, UAgriFlags.PAUSE_ORACLES, enabled, msg.sender);
    }
}
