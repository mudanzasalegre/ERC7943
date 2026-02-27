// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ComplianceModuleV1} from "../ComplianceModuleV1.sol";

import {UAgriErrors} from "../../interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "../../interfaces/constants/UAgriRoles.sol";
import {UAgriHazards} from "../../interfaces/constants/UAgriHazards.sol";

import {RoleManager} from "../../access/RoleManager.sol";

/// @title EUProfileEUDRCompliance
/// @notice “Profile plug-in” that derives ComplianceModuleV1.JurisdictionProfile based on:
///         - jurisdiction (e.g., ES=34),
///         - identity tier,
///         - active hazard (bytes32, e.g. UAgriHazards.FRAUD_OR_MATERIAL_BREACH).
///
/// @dev Intended usage patterns:
///   A) Governance tooling / scripts: call deriveProfile(...) and then cm.setProfile(jurisdiction, profile)
///      (static “materialization” into ComplianceModuleV1).
///   B) Future dynamic wiring: ComplianceModuleV1 could delegate to this contract per-call if you
///      decide to evolve the module (not required today).
contract EUProfileEUDRCompliance {
    // ------------------------------- Events ---------------------------------

    event EUJurisdictionSet(uint16 indexed jurisdiction, bool isEU);
    event DefaultEUProfileSet(ComplianceModuleV1.JurisdictionProfile profile);
    event DefaultNonEUProfileSet(ComplianceModuleV1.JurisdictionProfile profile);

    event JurisdictionOverrideSet(uint16 indexed jurisdiction, ComplianceModuleV1.JurisdictionProfile profile);

    event TierRuleSet(uint8 indexed tier, TierRule rule);
    event HazardRuleSet(bytes32 indexed hazard, HazardRule rule);

    // ------------------------------- Errors ---------------------------------

    error EUProfileEUDRCompliance__AlreadyInitialized();
    error EUProfileEUDRCompliance__InvalidRoleManager();
    error EUProfileEUDRCompliance__ArrayLengthMismatch();

    // ------------------------------- Storage --------------------------------

    RoleManager public roleManager;

    bool private _initialized;

    // jurisdiction => is EU
    mapping(uint16 => bool) public isEUJurisdiction;

    // Base default profiles
    ComplianceModuleV1.JurisdictionProfile private _defaultEU;
    ComplianceModuleV1.JurisdictionProfile private _defaultNonEU;

    // Optional per-jurisdiction override (if enabled=true, takes precedence)
    mapping(uint16 => ComplianceModuleV1.JurisdictionProfile) private _overrideProfile;

    // Tier rules (optional) to tune maxTransfer/minTtl/flags by tier
    struct TierRule {
        bool enabled;
        uint64 minTtlSeconds;      // increases min TTL requirement when expiry != 0
        uint128 maxTransfer;       // sets maxTransfer (0 = no cap)
        uint32 requiredFlags;      // OR into base requiredFlags
        uint32 forbiddenFlags;     // OR into base forbiddenFlags
    }

    mapping(uint8 => TierRule) private _tierRules;

    // Hazard rules (optional) to tighten policy when a hazard is active.
    struct HazardRule {
        bool enabled;

        uint8 minTierFloor;        // raise minTier (0 = no change)
        uint32 requiredFlags;      // OR into base requiredFlags
        uint32 forbiddenFlags;     // OR into base forbiddenFlags

        bool sameJurisdictionOnly;
        bool enforceLockupOnTransfer;

        // stricter cap (0 = no change). If base has cap, take min(non-zero).
        uint128 maxTransferCap;
    }

    mapping(bytes32 => HazardRule) private _hazardRules;

    // ------------------------------ Modifiers -------------------------------

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    // ------------------------------ Constructor -----------------------------

    constructor(address roleManager_) {
        _init(roleManager_);
    }

    function initialize(address roleManager_) external {
        _init(roleManager_);
    }

    function _init(address roleManager_) internal {
        if (_initialized) revert EUProfileEUDRCompliance__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert EUProfileEUDRCompliance__InvalidRoleManager();
        roleManager = RoleManager(roleManager_);

        // -------- Defaults (“fine by default, not brick”) --------
        _defaultEU = ComplianceModuleV1.JurisdictionProfile({
            enabled: true,
            requireIdentity: true,
            allowNoExpiry: false,              // EU: expiry required by default
            enforceLockupOnTransfer: true,
            sameJurisdictionOnly: false,
            minTier: 2,
            maxTier: 0,
            requiredFlags: 0,
            forbiddenFlags: 0,
            minTtlSeconds: 30 days,
            maxTransfer: 0
        });

        _defaultNonEU = ComplianceModuleV1.JurisdictionProfile({
            enabled: true,
            requireIdentity: true,
            allowNoExpiry: true,
            enforceLockupOnTransfer: true,
            sameJurisdictionOnly: false,
            minTier: 1,
            maxTier: 0,
            requiredFlags: 0,
            forbiddenFlags: 0,
            minTtlSeconds: 0,
            maxTransfer: 0
        });

        emit DefaultEUProfileSet(_defaultEU);
        emit DefaultNonEUProfileSet(_defaultNonEU);

        // Seed EU jurisdictions WITHOUT emitting 27 events (cheaper + less noisy).
        _seedEUJurisdictionsNoEvents();
    }

    function _seedEUJurisdictionsNoEvents() internal {
        // EU country calling codes (common E.164):
        // AT 43, BE 32, BG 359, HR 385, CY 357, CZ 420, DK 45, EE 372, FI 358, FR 33,
        // DE 49, GR 30, HU 36, IE 353, IT 39, LV 371, LT 370, LU 352, MT 356,
        // NL 31, PL 48, PT 351, RO 40, SK 421, SI 386, ES 34, SE 46.
        uint16[27] memory codes = [
            uint16(43),
            32,
            359,
            385,
            357,
            420,
            45,
            372,
            358,
            33,
            49,
            30,
            36,
            353,
            39,
            371,
            370,
            352,
            356,
            31,
            48,
            351,
            40,
            421,
            386,
            34,
            46
        ];

        for (uint256 i = 0; i < codes.length; i++) {
            isEUJurisdiction[codes[i]] = true;
        }
    }

    // ------------------------------ Views -----------------------------------

    function defaultEUProfile() external view returns (ComplianceModuleV1.JurisdictionProfile memory) {
        return _defaultEU;
    }

    function defaultNonEUProfile() external view returns (ComplianceModuleV1.JurisdictionProfile memory) {
        return _defaultNonEU;
    }

    function overrideProfileOf(uint16 jurisdiction) external view returns (ComplianceModuleV1.JurisdictionProfile memory) {
        return _overrideProfile[jurisdiction];
    }

    function tierRuleOf(uint8 tier) external view returns (TierRule memory) {
        return _tierRules[tier];
    }

    function hazardRuleOf(bytes32 hazard) external view returns (HazardRule memory) {
        return _hazardRules[hazard];
    }

    function deriveProfile(
        uint16 jurisdiction,
        uint8 tier,
        bytes32 hazard
    ) external view returns (ComplianceModuleV1.JurisdictionProfile memory p) {
        p = _baseProfile(jurisdiction);

        // Tier tuning
        TierRule memory tr = _tierRules[tier];
        if (tr.enabled) {
            if (tr.minTtlSeconds != 0 && p.minTtlSeconds < tr.minTtlSeconds) {
                p.minTtlSeconds = tr.minTtlSeconds;
            }

            if (tr.maxTransfer != 0) {
                p.maxTransfer = tr.maxTransfer;
            }

            if (tr.requiredFlags != 0) p.requiredFlags |= tr.requiredFlags;
            if (tr.forbiddenFlags != 0) p.forbiddenFlags |= tr.forbiddenFlags;
        }

        // Hazard tightening
        HazardRule memory hr = _hazardRules[hazard];
        if (hr.enabled) {
            if (hr.minTierFloor != 0 && p.minTier < hr.minTierFloor) p.minTier = hr.minTierFloor;

            if (hr.requiredFlags != 0) p.requiredFlags |= hr.requiredFlags;
            if (hr.forbiddenFlags != 0) p.forbiddenFlags |= hr.forbiddenFlags;

            if (hr.sameJurisdictionOnly) p.sameJurisdictionOnly = true;
            if (hr.enforceLockupOnTransfer) p.enforceLockupOnTransfer = true;

            if (hr.maxTransferCap != 0) {
                if (p.maxTransfer == 0 || hr.maxTransferCap < p.maxTransfer) {
                    p.maxTransfer = hr.maxTransferCap;
                }
            }
        }

        return p;
    }

    function baseProfile(uint16 jurisdiction) external view returns (ComplianceModuleV1.JurisdictionProfile memory) {
        return _baseProfile(jurisdiction);
    }

    function _baseProfile(uint16 jurisdiction) internal view returns (ComplianceModuleV1.JurisdictionProfile memory p) {
        ComplianceModuleV1.JurisdictionProfile memory ov = _overrideProfile[jurisdiction];
        if (ov.enabled) return ov;

        if (jurisdiction != 0 && isEUJurisdiction[jurisdiction]) return _defaultEU;
        return _defaultNonEU;
    }

    // ------------------------------ Governance ------------------------------

    function setEUJurisdiction(uint16 jurisdiction, bool yes) external onlyGovernance {
        isEUJurisdiction[jurisdiction] = yes;
        emit EUJurisdictionSet(jurisdiction, yes);
    }

    function setEUJurisdictions(uint16[] calldata jurisdictions, bool yes) external onlyGovernance {
        uint256 n = jurisdictions.length;
        for (uint256 i = 0; i < n; i++) {
            uint16 j = jurisdictions[i];
            isEUJurisdiction[j] = yes;
            emit EUJurisdictionSet(j, yes);
        }
    }

    function setDefaultEUProfile(ComplianceModuleV1.JurisdictionProfile calldata profile) external onlyGovernance {
        _defaultEU = profile;
        emit DefaultEUProfileSet(profile);
    }

    function setDefaultNonEUProfile(ComplianceModuleV1.JurisdictionProfile calldata profile) external onlyGovernance {
        _defaultNonEU = profile;
        emit DefaultNonEUProfileSet(profile);
    }

    function setJurisdictionOverride(uint16 jurisdiction, ComplianceModuleV1.JurisdictionProfile calldata profile)
        external
        onlyGovernance
    {
        _overrideProfile[jurisdiction] = profile;
        emit JurisdictionOverrideSet(jurisdiction, profile);
    }

    function setJurisdictionOverrideBatch(
        uint16[] calldata jurisdictions,
        ComplianceModuleV1.JurisdictionProfile[] calldata profiles
    ) external onlyGovernance {
        if (jurisdictions.length != profiles.length) revert EUProfileEUDRCompliance__ArrayLengthMismatch();

        uint256 n = jurisdictions.length;
        for (uint256 i = 0; i < n; i++) {
            uint16 j = jurisdictions[i];
            ComplianceModuleV1.JurisdictionProfile calldata p = profiles[i];
            _overrideProfile[j] = p;
            emit JurisdictionOverrideSet(j, p);
        }
    }

    // ---- Tier rules ----

    function setTierRule(uint8 tier, TierRule calldata rule) external onlyGovernance {
        _tierRules[tier] = rule;
        emit TierRuleSet(tier, rule);
    }

    function setTierRuleBatch(uint8[] calldata tiers, TierRule[] calldata rules) external onlyGovernance {
        if (tiers.length != rules.length) revert EUProfileEUDRCompliance__ArrayLengthMismatch();

        uint256 n = tiers.length;
        for (uint256 i = 0; i < n; i++) {
            uint8 t = tiers[i];
            TierRule calldata r = rules[i];
            _tierRules[t] = r;
            emit TierRuleSet(t, r);
        }
    }

    // ---- Hazard rules ----

    function setHazardRule(bytes32 hazard, HazardRule calldata rule) external onlyGovernance {
        _hazardRules[hazard] = rule;
        emit HazardRuleSet(hazard, rule);
    }

    function setHazardRuleBatch(bytes32[] calldata hazards, HazardRule[] calldata rules) external onlyGovernance {
        if (hazards.length != rules.length) revert EUProfileEUDRCompliance__ArrayLengthMismatch();

        uint256 n = hazards.length;
        for (uint256 i = 0; i < n; i++) {
            bytes32 h = hazards[i];
            HazardRule calldata r = rules[i];
            _hazardRules[h] = r;
            emit HazardRuleSet(h, r);
        }
    }

    /// @notice Optional helper: installs a sensible EUDR-ish tightening preset for common hazards.
    function installDefaultEUDRHazardPreset() external onlyGovernance {
        _hazardRules[UAgriHazards.FRAUD_OR_MATERIAL_BREACH] = HazardRule({
            enabled: true,
            minTierFloor: 3,
            requiredFlags: 0,
            forbiddenFlags: 0,
            sameJurisdictionOnly: true,
            enforceLockupOnTransfer: true,
            maxTransferCap: 0
        });
        emit HazardRuleSet(
            UAgriHazards.FRAUD_OR_MATERIAL_BREACH,
            _hazardRules[UAgriHazards.FRAUD_OR_MATERIAL_BREACH]
        );

        _hazardRules[UAgriHazards.SUPPLY_CHAIN_DISRUPTION] = HazardRule({
            enabled: true,
            minTierFloor: 0,
            requiredFlags: 0,
            forbiddenFlags: 0,
            sameJurisdictionOnly: false,
            enforceLockupOnTransfer: true,
            maxTransferCap: 0
        });
        emit HazardRuleSet(
            UAgriHazards.SUPPLY_CHAIN_DISRUPTION,
            _hazardRules[UAgriHazards.SUPPLY_CHAIN_DISRUPTION]
        );

        _hazardRules[UAgriHazards.GOV_ACTION] = HazardRule({
            enabled: true,
            minTierFloor: 3,
            requiredFlags: 0,
            forbiddenFlags: 0,
            sameJurisdictionOnly: true,
            enforceLockupOnTransfer: true,
            maxTransferCap: 0
        });
        emit HazardRuleSet(UAgriHazards.GOV_ACTION, _hazardRules[UAgriHazards.GOV_ACTION]);

        _hazardRules[UAgriHazards.EXPROPRIATION_OR_ACCESS_LOSS] = HazardRule({
            enabled: true,
            minTierFloor: 3,
            requiredFlags: 0,
            forbiddenFlags: 0,
            sameJurisdictionOnly: true,
            enforceLockupOnTransfer: true,
            maxTransferCap: 0
        });
        emit HazardRuleSet(
            UAgriHazards.EXPROPRIATION_OR_ACCESS_LOSS,
            _hazardRules[UAgriHazards.EXPROPRIATION_OR_ACCESS_LOSS]
        );
    }

    // ------------------------------ RBAC ------------------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, caller)
        ) return;

        revert UAgriErrors.UAgri__Unauthorized();
    }
}
