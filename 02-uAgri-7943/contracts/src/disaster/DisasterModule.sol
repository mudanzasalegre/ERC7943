// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriDisasterV1} from "../interfaces/v1/IAgriDisasterV1.sol";
import {IAgriDisasterAdminV1} from "../interfaces/v1/IAgriDisasterAdminV1.sol";

import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";
import {UAgriFlags} from "../interfaces/constants/UAgriFlags.sol";

import {RoleManager} from "../access/RoleManager.sol";

/// @title DisasterModule
/// @notice Disaster & emergency controls (pauses + restricted/hardFrozen + hazards) per campaign.
/// @dev Standard-grade behavior aligned to the “receta maestra” semantics:
///  - Levels (severity 0..4):
///      * 0: none
///      * 1: ALERT (soft) -> default auto-pause FUNDING (configurable here)
///      * 2: RESTRICTED  -> default auto-pause REDEMPTIONS + CLAIMS
///      * 3-4: HARD_FREEZE -> default auto-pause TRANSFERS (hard action)
///  - Hard actions must be governance-confirmed:
///      * If a non-confirmed TTL declaration requests HARD_FREEZE, effective level is DOWNGRADED to RESTRICTED
///        until governance confirms.
///  - Manual pause flags are stored separately and OR-ed with auto-pause flags, so operational pauses
///    are not lost when TTL expires or when restricted/hardFrozen toggles.
///  - View paths are designed to NOT revert.
contract DisasterModule is IAgriDisasterV1, IAgriDisasterAdminV1 {
    // -------------------------------- Errors --------------------------------

    error DisasterModule__AlreadyInitialized();
    error DisasterModule__InvalidRoleManager();
    error DisasterModule__InvalidSeverity();
    error DisasterModule__InvalidExpiresAt();
    error DisasterModule__TtlRequired();
    error DisasterModule__UnknownFlags(uint256 provided, uint256 allowed);
    error DisasterModule__DisasterExpired();
    error DisasterModule__NoActiveDisaster();

    // -------------------------------- Storage -------------------------------

    RoleManager public roleManager;
    bool private _initialized;

    mapping(bytes32 => DisasterState) private _states;

    /// @dev Manual pause flags (ONLY UAgriFlags pause bits). Auto-pauses are derived from severity/high bits.
    mapping(bytes32 => uint256) private _manualPauseFlags;

    // ------------------------------ Flag Bits -------------------------------

    // Pause flags are defined in UAgriFlags (low bits).
    uint256 internal constant PAUSE_MASK =
        UAgriFlags.PAUSE_TRANSFERS |
        UAgriFlags.PAUSE_FUNDING |
        UAgriFlags.PAUSE_REDEMPTIONS |
        UAgriFlags.PAUSE_CLAIMS |
        UAgriFlags.PAUSE_ORACLES;

    // Auto-pause for ALERT (soft restrictions).
    // Receta maestra: “Alert (suave)” — aquí lo implementamos como pausar FUNDING por defecto.
    uint256 internal constant ALERT_AUTO_PAUSE_MASK =
        UAgriFlags.PAUSE_FUNDING;

    // Auto-pause for RESTRICTED:
    // Receta maestra: “Restricted (pausa redemption/claim por defecto)”
    uint256 internal constant RESTRICTED_AUTO_PAUSE_MASK =
        UAgriFlags.PAUSE_REDEMPTIONS |
        UAgriFlags.PAUSE_CLAIMS;

    // Auto-pause for HARD_FREEZE:
    // Receta maestra: “HardFreeze (pausa transfers; solo acciones judiciales/reestructuración)”
    uint256 internal constant HARD_FREEZE_AUTO_PAUSE_MASK =
        UAgriFlags.PAUSE_TRANSFERS;

    // High bits reserved for restricted/hardFrozen (avoid collisions with low pause bits).
    uint256 internal constant FLAG_HARD_FROZEN = uint256(1) << 254;
    uint256 internal constant FLAG_RESTRICTED  = uint256(1) << 255;

    uint256 internal constant ALLOWED_FLAGS = PAUSE_MASK | FLAG_HARD_FROZEN | FLAG_RESTRICTED;

    // ------------------------------- Events ---------------------------------

    /// @notice Emitted when manual pause flags are updated (extra event, not in the interface).
    event ManualPauseFlagsUpdated(bytes32 indexed campaignId, uint256 manualPauseFlags, address indexed caller);

    // ------------------------------ Modifiers -------------------------------

    modifier onlyDisasterOperator() {
        _requireDisasterOperator();
        _;
    }

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    // ------------------------------ Init ------------------------------------

    constructor(address roleManager_) {
        _init(roleManager_);
    }

    function initialize(address roleManager_) external {
        _init(roleManager_);
    }

    function _init(address roleManager_) internal {
        if (_initialized) revert DisasterModule__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert DisasterModule__InvalidRoleManager();
        roleManager = RoleManager(roleManager_);
    }

    // --------------------------- IAgriDisasterV1 ----------------------------

    /// @inheritdoc IAgriDisasterV1
    function campaignFlags(bytes32 campaignId) external view returns (uint256 flags) {
        // Only pause bits, EmergencyPause-compatible.
        DisasterState memory st = _snapshot(campaignId);
        return st.flags & PAUSE_MASK;
    }

    /// @inheritdoc IAgriDisasterV1
    function isRestricted(bytes32 campaignId) external view returns (bool) {
        DisasterState memory st = _snapshot(campaignId);
        return (st.flags & FLAG_RESTRICTED) != 0;
    }

    /// @inheritdoc IAgriDisasterV1
    function isHardFrozen(bytes32 campaignId) external view returns (bool) {
        DisasterState memory st = _snapshot(campaignId);
        return (st.flags & FLAG_HARD_FROZEN) != 0;
    }

    // ------------------------ IAgriDisasterAdminV1 --------------------------

    /// @inheritdoc IAgriDisasterAdminV1
    function getDisaster(bytes32 campaignId) external view returns (DisasterState memory) {
        return _snapshot(campaignId);
    }

    /// @inheritdoc IAgriDisasterAdminV1
    function declareDisaster(
        bytes32 campaignId,
        bytes32 hazardCode,
        uint8 severity,
        bytes32 reasonHash,
        uint64 ttlSeconds
    ) external onlyDisasterOperator {
        if (severity > 4) revert DisasterModule__InvalidSeverity();

        bool gov = _isGovernance(msg.sender);

        // TTL fast-path: for non-governance callers we require a TTL.
        if (!gov && ttlSeconds == 0) revert DisasterModule__TtlRequired();

        uint64 nowTs = uint64(block.timestamp);
        uint64 expiresAt = 0;

        if (ttlSeconds != 0) {
            unchecked { expiresAt = nowTs + ttlSeconds; }
            if (expiresAt <= nowTs) revert DisasterModule__InvalidExpiresAt();
        }

        // Auto policy (requested high bits) derived from severity.
        uint256 requestedHigh = _highBitsFromSeverity(severity);

        DisasterState storage st = _states[campaignId];
        st.hazardCode = hazardCode;
        st.severity = severity;
        st.reasonHash = reasonHash;
        st.expiresAt = expiresAt;

        // Only governance can create a no-TTL declaration; treat it as confirmed.
        st.confirmed = (ttlSeconds == 0) && gov;

        // Store only the requested high bits; effective level may be downgraded in views if not confirmed.
        st.flags = _normalizeHighBits(requestedHigh);

        // Emit with EFFECTIVE flags (high + manual + auto) for transparency.
        DisasterState memory snap = _snapshot(campaignId);
        emit DisasterDeclared(campaignId, hazardCode, severity, snap.flags, expiresAt, reasonHash);

        if (st.confirmed) {
            emit DisasterConfirmed(campaignId, severity, snap.flags);
        }
    }

    /// @inheritdoc IAgriDisasterAdminV1
    function confirmDisaster(bytes32 campaignId, uint256 flags, uint8 severity) external onlyGovernance {
        if (severity > 4) revert DisasterModule__InvalidSeverity();
        if ((flags & ~ALLOWED_FLAGS) != 0) revert DisasterModule__UnknownFlags(flags, ALLOWED_FLAGS);

        DisasterState storage cur = _states[campaignId];

        // Must be an active, non-expired disaster to confirm (interface doesn't pass hazard/reason).
        if (cur.severity == 0 && cur.hazardCode == bytes32(0) && cur.reasonHash == bytes32(0)) {
            revert DisasterModule__NoActiveDisaster();
        }

        // If there was a TTL-based (unconfirmed) disaster and it already expired, force a re-declare.
        if (!cur.confirmed && cur.expiresAt != 0 && uint64(block.timestamp) >= cur.expiresAt) {
            revert DisasterModule__DisasterExpired();
        }

        // Enforce consistency between severity and high bits (standard-grade).
        uint256 impliedHigh = _highBitsFromSeverity(severity);
        uint256 providedHigh = flags & (FLAG_HARD_FROZEN | FLAG_RESTRICTED);
        if (providedHigh == 0) {
            providedHigh = impliedHigh;
        } else if (_normalizeHighBits(providedHigh) != _normalizeHighBits(impliedHigh)) {
            // Caller should pass a severity that matches the intended confirmed mode.
            revert DisasterModule__InvalidSeverity();
        }

        // Manual pause bits come from flags low bits.
        uint256 manual = flags & PAUSE_MASK;
        _manualPauseFlags[campaignId] = manual;
        emit ManualPauseFlagsUpdated(campaignId, manual, msg.sender);

        // Apply confirmation.
        cur.flags = _normalizeHighBits(providedHigh);
        cur.severity = severity;
        cur.expiresAt = 0;
        cur.confirmed = true;

        // Emit effective flags (high + manual + auto).
        DisasterState memory snap = _snapshot(campaignId);
        emit DisasterConfirmed(campaignId, severity, snap.flags);
    }

    /// @inheritdoc IAgriDisasterAdminV1
    function clearDisaster(bytes32 campaignId) external onlyGovernance {
        delete _states[campaignId];
        delete _manualPauseFlags[campaignId];
        emit DisasterCleared(campaignId);
    }

    // ---------------------- Optional manual pause API -----------------------
    // (Not in the interfaces, but useful to "englobar" EmergencyPause.)

    /// @notice Sets manual pause flags exactly (pause bits only). Does not change hazard/restricted/hardFrozen.
    function setManualPauseFlags(bytes32 campaignId, uint256 flags) external onlyDisasterOperator {
        _setManualPauseFlags(campaignId, flags, 0);
    }

    /// @notice ORs manual pause flags (pause bits only).
    function orManualPauseFlags(bytes32 campaignId, uint256 flags) external onlyDisasterOperator {
        _setManualPauseFlags(campaignId, flags, 1);
    }

    /// @notice ANDs manual pause flags (pause bits only). (flags=0 => clears all manual pauses)
    function andManualPauseFlags(bytes32 campaignId, uint256 flags) external onlyDisasterOperator {
        _setManualPauseFlags(campaignId, flags, 2);
    }

    /// @notice Returns manual pause flags (pause bits only).
    function manualPauseFlags(bytes32 campaignId) external view returns (uint256) {
        return _manualPauseFlags[campaignId] & PAUSE_MASK;
    }

    // ------------------------------ Internals -------------------------------

    /// @dev mode: 0=set exact, 1=OR, 2=AND
    function _setManualPauseFlags(bytes32 campaignId, uint256 flags, uint8 mode) internal {
        if ((flags & ~PAUSE_MASK) != 0) revert DisasterModule__UnknownFlags(flags, PAUSE_MASK);

        uint256 oldManual = _manualPauseFlags[campaignId] & PAUSE_MASK;
        uint256 newManual;

        if (mode == 0) newManual = flags;
        else if (mode == 1) newManual = oldManual | flags;
        else newManual = oldManual & flags;

        _manualPauseFlags[campaignId] = newManual;
        emit ManualPauseFlagsUpdated(campaignId, newManual, msg.sender);
    }

    /// @dev View snapshot that composes effective flags:
    ///      - TTL expiry clears hazard/restricted/hardFrozen (if not confirmed) but keeps manual pauses.
    ///      - HardFreeze is only effective when confirmed; otherwise downgraded to Restricted.
    function _snapshot(bytes32 campaignId) internal view returns (DisasterState memory st) {
        st = _states[campaignId];

        // If TTL expired and not confirmed: treat hazard + high-bits as cleared,
        // BUT keep manual pause flags (operational pauses persist).
        if (!st.confirmed && st.expiresAt != 0 && uint64(block.timestamp) >= st.expiresAt) {
            st.hazardCode = bytes32(0);
            st.reasonHash = bytes32(0);
            st.severity = 0;
            st.expiresAt = 0;
            st.confirmed = false;
            st.flags = 0;
        }

        uint256 requestedHigh = _normalizeHighBits(st.flags & (FLAG_HARD_FROZEN | FLAG_RESTRICTED));

        // Enforce “hard actions must be confirmed”:
        // If not confirmed and requested HARD_FREEZE => downgrade effective high to RESTRICTED.
        uint256 effectiveHigh = requestedHigh;
        if (!st.confirmed && effectiveHigh == FLAG_HARD_FROZEN) {
            effectiveHigh = FLAG_RESTRICTED;
        }

        // Auto pause based on effective mode + alert severity.
        uint256 autoPause = 0;

        if (effectiveHigh == FLAG_HARD_FROZEN) {
            autoPause = HARD_FREEZE_AUTO_PAUSE_MASK;
        } else if (effectiveHigh == FLAG_RESTRICTED) {
            autoPause = RESTRICTED_AUTO_PAUSE_MASK;
        } else {
            // ALERT: soft restrictions (severity==1) without high bits.
            if (st.severity == 1) autoPause = ALERT_AUTO_PAUSE_MASK;
        }

        // Manual pauses are always applied.
        uint256 manual = _manualPauseFlags[campaignId] & PAUSE_MASK;

        // Effective flags returned by getDisaster() include:
        //   [high bits restricted/hardFrozen] + [pause bits (manual|auto)]
        st.flags = effectiveHigh | ((autoPause | manual) & PAUSE_MASK);
        return st;
    }

    /// @dev severity mapping to high bits:
    ///      0/1 => none (Alert has no high bits)
    ///      2   => restricted
    ///      3/4 => hard frozen
    function _highBitsFromSeverity(uint8 severity) internal pure returns (uint256 high) {
        if (severity >= 3) return FLAG_HARD_FROZEN;
        if (severity == 2) return FLAG_RESTRICTED;
        return 0;
    }

    function _normalizeHighBits(uint256 high) internal pure returns (uint256) {
        // If hardFrozen is set, we ignore restricted (hardFrozen dominates).
        if ((high & FLAG_HARD_FROZEN) != 0) return FLAG_HARD_FROZEN;
        if ((high & FLAG_RESTRICTED) != 0) return FLAG_RESTRICTED;
        return 0;
    }

    // ------------------------------ RBAC ------------------------------------

    function _isGovernance(address a) internal view returns (bool) {
        RoleManager rm = roleManager;
        address rma = address(rm);
        if (rma == address(0) || rma.code.length == 0) return false;
        return rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, a) || rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, a);
    }

    function _requireGovernance() internal view {
        if (_isGovernance(msg.sender)) return;
        revert UAgriErrors.UAgri__Unauthorized();
    }

    function _requireDisasterOperator() internal view {
        RoleManager rm = roleManager;
        address rma = address(rm);
        if (rma == address(0) || rma.code.length == 0) revert UAgriErrors.UAgri__Unauthorized();

        address caller = msg.sender;

        // Operators: governance + disaster admin + guardian.
        if (
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.DISASTER_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GUARDIAN_ROLE, caller)
        ) {
            return;
        }

        revert UAgriErrors.UAgri__Unauthorized();
    }
}
