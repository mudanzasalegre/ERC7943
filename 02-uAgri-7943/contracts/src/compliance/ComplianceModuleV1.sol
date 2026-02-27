// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriComplianceV1} from "../interfaces/v1/IAgriComplianceV1.sol";
import {
    IAgriIdentityAttestationV1
} from "../interfaces/v1/IAgriIdentityAttestationV1.sol";

import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

import {RoleManager} from "../access/RoleManager.sol";
import {SafeStaticCall} from "../_shared/SafeStaticCall.sol";

/// @title ComplianceModuleV1
/// @notice Compliance checks for ERC-7943 token enforcement.
/// @dev Design goals:
///  - VIEW calls MUST NOT revert (token calls this via gas-capped staticcalls; fail-closed on errors)
///  - Identity attestation is the primary signal (jurisdiction/tier/flags/expiry/lockup)
///  - Jurisdiction profiles provide policy (tier ranges, required/forbidden flags, max transfer, etc.)
///  - Deny/sanctions lists block accounts immediately
///  - Optional: block transfers between jurisdiction pairs
contract ComplianceModuleV1 is IAgriComplianceV1 {
    // ------------------------------- Events ---------------------------------

    event IdentityAttestationUpdated(
        address indexed oldAddr,
        address indexed newAddr
    );
    event PausedSet(bool paused);

    event ExemptSet(address indexed account, bool exempt);
    event DenylistedSet(address indexed account, bool denied);
    event SanctionedSet(address indexed account, bool sanctioned);

    event ProfileSet(uint16 indexed jurisdiction, JurisdictionProfile profile);
    event PairBlockedSet(
        uint16 indexed fromJurisdiction,
        uint16 indexed toJurisdiction,
        bool blocked
    );

    // ------------------------------- Errors ---------------------------------

    error ComplianceModuleV1__AlreadyInitialized();
    error ComplianceModuleV1__InvalidRoleManager();
    error ComplianceModuleV1__InvalidIdentityAttestation();
    error ComplianceModuleV1__ArrayLengthMismatch();

    // ----------------------------- Status Codes -----------------------------

    // 0 = OK
    uint8 internal constant CODE_OK = 0;

    // 1.. = common blocking reasons
    uint8 internal constant CODE_PAUSED = 1;

    // account-side denials
    uint8 internal constant CODE_FROM_DENY_OR_SANCTION = 10;
    uint8 internal constant CODE_TO_DENY_OR_SANCTION = 11;

    uint8 internal constant CODE_PROFILE_DISABLED = 20;

    // identity problems
    uint8 internal constant CODE_IDENTITY_MISSING_OR_INVALID = 30;
    uint8 internal constant CODE_IDENTITY_EXPIRED = 31;
    uint8 internal constant CODE_IDENTITY_TTL_TOO_LOW = 32;
    uint8 internal constant CODE_TIER_OUT_OF_RANGE = 33;
    uint8 internal constant CODE_FLAGS_MISMATCH = 34;
    uint8 internal constant CODE_NO_EXPIRY_NOT_ALLOWED = 35;

    // transfer-specific
    uint8 internal constant CODE_LOCKED = 40;
    uint8 internal constant CODE_PAIR_BLOCKED = 41;
    uint8 internal constant CODE_AMOUNT_TOO_LARGE = 42;

    // catch-all fail-closed
    uint8 internal constant CODE_FAIL_CLOSED = 255;

    // -------------------------- Identity staticcall --------------------------

    // ABI-encoded Payload tuple = 6 * 32 bytes = 192 bytes minimum.
    uint32 internal constant IDENTITY_MIN_RET_BYTES = 192;
    // Return cap a little above 192.
    uint32 internal constant IDENTITY_MAX_RET_BYTES = 224;
    // Gas stipend for identityOf() to avoid eating the whole view gas budget.
    uint32 internal constant IDENTITY_GAS_STIPEND = 25_000;

    // ------------------------------- Profile --------------------------------

    /// @notice Jurisdiction policy profile.
    /// @dev Notes:
    ///  - If profile for `jurisdiction` is not enabled, we fall back to profile[0] (default),
    ///    if enabled; otherwise fail-closed.
    ///  - `maxTier == 0` means "no max" (only minTier applies).
    ///  - `minTtlSeconds` applies only if expiry != 0 (otherwise controlled by allowNoExpiry).
    ///  - `enforceLockupOnTransfer` controls using payload.lockupUntil for outgoing transfers.
    ///  - `sameJurisdictionOnly` enforces fromJurisdiction == toJurisdiction (in addition to pair blocks).
    struct JurisdictionProfile {
        bool enabled;
        // Identity requirements
        bool requireIdentity; // if true, missing/invalid identity fails canTransact/canTransfer
        bool allowNoExpiry; // if false, payload.expiry must be != 0
        // Transfer constraints
        bool enforceLockupOnTransfer; // if true, block outgoing transfers while now < lockupUntil
        bool sameJurisdictionOnly; // if true, require fromJ == toJ
        // Tier & flags constraints
        uint8 minTier; // inclusive
        uint8 maxTier; // inclusive, 0 => no max
        uint32 requiredFlags; // must be set
        uint32 forbiddenFlags; // must be unset
        // Expiry quality constraint
        uint64 minTtlSeconds; // require (expiry - now) >= minTtlSeconds when expiry != 0
        // Amount constraint (per transfer)
        uint128 maxTransfer; // 0 => no limit
    }

    // ------------------------------- Storage --------------------------------

    RoleManager public roleManager;
    address public identityAttestation;

    bool public paused;

    // Exempt addresses bypass identity/profile checks (BUT NOT deny/sanctions).
    mapping(address => bool) public isExempt;

    // Lists
    mapping(address => bool) public isDenylisted;
    mapping(address => bool) public isSanctioned;

    // Profiles by jurisdiction (0 = default profile).
    mapping(uint16 => JurisdictionProfile) private _profiles;

    // Optional: block specific jurisdiction pairs.
    // If pairBlocked[fromJ][toJ] == true => transfer denied.
    mapping(uint16 => mapping(uint16 => bool)) public pairBlocked;

    bool private _initialized;

    // ------------------------------ Modifiers -------------------------------

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    // ------------------------------ Init ------------------------------------

    constructor(address roleManager_, address identityAttestation_) {
        _init(roleManager_, identityAttestation_);
    }

    function initialize(
        address roleManager_,
        address identityAttestation_
    ) external {
        _init(roleManager_, identityAttestation_);
    }

    function _init(
        address roleManager_,
        address identityAttestation_
    ) internal {
        if (_initialized) revert ComplianceModuleV1__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0))
            revert ComplianceModuleV1__InvalidRoleManager();
        roleManager = RoleManager(roleManager_);

        _setIdentityAttestationInternal(identityAttestation_);

        // Default profile at jurisdiction 0 (fallback).
        _profiles[0] = JurisdictionProfile({
            enabled: true,
            requireIdentity: true,
            allowNoExpiry: true,
            enforceLockupOnTransfer: true,
            sameJurisdictionOnly: false,
            minTier: 0,
            maxTier: 0,
            requiredFlags: 0,
            forbiddenFlags: 0,
            minTtlSeconds: 0,
            maxTransfer: 0
        });

        emit ProfileSet(0, _profiles[0]);
    }

    // --------------------------- IAgriComplianceV1 ---------------------------

    function canTransact(address account) external view returns (bool) {
        (bool ok, ) = _statusTransact(account);
        return ok;
    }

    function canTransfer(
        address from,
        address to,
        uint256 amount
    ) external view returns (bool) {
        (bool ok, ) = _statusTransfer(from, to, amount);
        return ok;
    }

    function transferStatus(
        address from,
        address to,
        uint256 amount
    ) external view returns (bool ok, uint8 code) {
        return _statusTransfer(from, to, amount);
    }

    // -------------------------- Extra DX (optional) --------------------------

    /// @notice Like transferStatus but for canTransact checks (no interface change).
    function transactStatus(
        address account
    ) external view returns (bool ok, uint8 code) {
        return _statusTransact(account);
    }

    // ----------------------------- Governance API ----------------------------

    function setPaused(bool paused_) external onlyGovernance {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setIdentityAttestation(
        address identityAttestation_
    ) external onlyGovernance {
        _setIdentityAttestationInternal(identityAttestation_);
    }

    function _setIdentityAttestationInternal(
        address identityAttestation_
    ) internal {
        if (identityAttestation_ == address(0))
            revert ComplianceModuleV1__InvalidIdentityAttestation();
        if (identityAttestation_.code.length == 0)
            revert ComplianceModuleV1__InvalidIdentityAttestation();

        address old = identityAttestation;
        identityAttestation = identityAttestation_;

        emit IdentityAttestationUpdated(old, identityAttestation_);
    }

    // ---- Exempt ----

    function setExempt(address account, bool exempt) external onlyGovernance {
        if (account == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        isExempt[account] = exempt;
        emit ExemptSet(account, exempt);
    }

    function setExemptBatch(
        address[] calldata accounts,
        bool exempt
    ) external onlyGovernance {
        uint256 n = accounts.length;
        for (uint256 i = 0; i < n; i++) {
            address a = accounts[i];
            if (a == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
            isExempt[a] = exempt;
            emit ExemptSet(a, exempt);
        }
    }

    // ---- Denylist / Sanctions ----

    function setDenylisted(
        address account,
        bool denied
    ) external onlyGovernance {
        if (account == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        isDenylisted[account] = denied;
        emit DenylistedSet(account, denied);
    }

    function setDenylistedBatch(
        address[] calldata accounts,
        bool denied
    ) external onlyGovernance {
        uint256 n = accounts.length;
        for (uint256 i = 0; i < n; i++) {
            address a = accounts[i];
            if (a == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
            isDenylisted[a] = denied;
            emit DenylistedSet(a, denied);
        }
    }

    function setSanctioned(
        address account,
        bool sanctioned
    ) external onlyGovernance {
        if (account == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        isSanctioned[account] = sanctioned;
        emit SanctionedSet(account, sanctioned);
    }

    function setSanctionedBatch(
        address[] calldata accounts,
        bool sanctioned
    ) external onlyGovernance {
        uint256 n = accounts.length;
        for (uint256 i = 0; i < n; i++) {
            address a = accounts[i];
            if (a == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
            isSanctioned[a] = sanctioned;
            emit SanctionedSet(a, sanctioned);
        }
    }

    // ---- Profiles ----

    function profileOf(
        uint16 jurisdiction
    ) external view returns (JurisdictionProfile memory) {
        JurisdictionProfile memory p = _profiles[jurisdiction];
        if (!p.enabled && jurisdiction != 0) {
            JurisdictionProfile memory d = _profiles[0];
            if (d.enabled) return d;
        }
        return p;
    }

    function setProfile(
        uint16 jurisdiction,
        JurisdictionProfile calldata profile
    ) external onlyGovernance {
        _profiles[jurisdiction] = profile;
        emit ProfileSet(jurisdiction, profile);
    }

    function setProfileBatch(
        uint16[] calldata jurisdictions,
        JurisdictionProfile[] calldata profiles_
    ) external onlyGovernance {
        if (jurisdictions.length != profiles_.length)
            revert ComplianceModuleV1__ArrayLengthMismatch();
        uint256 n = jurisdictions.length;
        for (uint256 i = 0; i < n; i++) {
            uint16 j = jurisdictions[i];
            JurisdictionProfile calldata p = profiles_[i];
            _profiles[j] = p;
            emit ProfileSet(j, p);
        }
    }

    // ---- Pair blocks ----

    function setPairBlocked(
        uint16 fromJurisdiction,
        uint16 toJurisdiction,
        bool blocked
    ) external onlyGovernance {
        pairBlocked[fromJurisdiction][toJurisdiction] = blocked;
        emit PairBlockedSet(fromJurisdiction, toJurisdiction, blocked);
    }

    function setPairBlockedBatch(
        uint16[] calldata fromJurisdictions,
        uint16[] calldata toJurisdictions,
        bool blocked
    ) external onlyGovernance {
        if (fromJurisdictions.length != toJurisdictions.length)
            revert ComplianceModuleV1__ArrayLengthMismatch();
        uint256 n = fromJurisdictions.length;
        for (uint256 i = 0; i < n; i++) {
            uint16 fj = fromJurisdictions[i];
            uint16 tj = toJurisdictions[i];
            pairBlocked[fj][tj] = blocked;
            emit PairBlockedSet(fj, tj, blocked);
        }
    }

    // ----------------------------- Internal Logic ----------------------------

    function _statusTransact(
        address account
    ) internal view returns (bool ok, uint8 code) {
        // Fail-closed, never revert.
        if (paused) return (false, CODE_PAUSED);
        if (account == address(0)) return (false, CODE_FAIL_CLOSED);

        // ✅ Seguridad: listas SIEMPRE ganan incluso si esExempt.
        if (isDenylisted[account] || isSanctioned[account])
            return (false, CODE_FROM_DENY_OR_SANCTION);

        // Exempt: bypass identidad/perfil (pero no sanciones/denylist, ya chequeadas).
        if (isExempt[account]) return (true, CODE_OK);

        (
            bool idOk,
            IAgriIdentityAttestationV1.Payload memory idp
        ) = _safeIdentityOf(account);

        uint16 juris = (idOk && idp.providerId != 0) ? idp.jurisdiction : 0;
        JurisdictionProfile memory p = _effectiveProfile(juris);
        if (!p.enabled) return (false, CODE_PROFILE_DISABLED);

        if (p.requireIdentity) {
            if (!idOk || idp.providerId == 0)
                return (false, CODE_IDENTITY_MISSING_OR_INVALID);
        }

        if (idOk && idp.providerId != 0) {
            (bool valid, uint8 why) = _validateIdentity(
                idp,
                p,
                uint64(block.timestamp)
            );
            if (!valid) return (false, why);
        } else {
            if (p.requireIdentity)
                return (false, CODE_IDENTITY_MISSING_OR_INVALID);
        }

        return (true, CODE_OK);
    }

    function _statusTransfer(
        address from,
        address to,
        uint256 amount
    ) internal view returns (bool ok, uint8 code) {
        // Fail-closed, never revert.
        if (paused) return (false, CODE_PAUSED);
        if (from == address(0) || to == address(0))
            return (false, CODE_FAIL_CLOSED);

        // ✅ Seguridad: listas ganan siempre (aunque haya exención).
        if (isDenylisted[from] || isSanctioned[from])
            return (false, CODE_FROM_DENY_OR_SANCTION);
        if (isDenylisted[to] || isSanctioned[to])
            return (false, CODE_TO_DENY_OR_SANCTION);

        // Exempt short-circuit:
        // - If both are exempt => allow (still blocked by lists above)
        if (isExempt[from] && isExempt[to]) return (true, CODE_OK);

        // Fetch identities only for non-exempt sides (gas saving + avoids forced identity for modules)
        (
            bool fromOk,
            IAgriIdentityAttestationV1.Payload memory fromId
        ) = isExempt[from]
                ? (false, IAgriIdentityAttestationV1.Payload(0, 0, 0, 0, 0, 0))
                : _safeIdentityOf(from);

        (bool toOk, IAgriIdentityAttestationV1.Payload memory toId) = isExempt[
            to
        ]
            ? (false, IAgriIdentityAttestationV1.Payload(0, 0, 0, 0, 0, 0))
            : _safeIdentityOf(to);

        uint16 fromJ = (fromOk && fromId.providerId != 0)
            ? fromId.jurisdiction
            : 0;
        uint16 toJ = (toOk && toId.providerId != 0) ? toId.jurisdiction : 0;

        JurisdictionProfile memory fromP = _effectiveProfile(fromJ);
        JurisdictionProfile memory toP = _effectiveProfile(toJ);

        if (!fromP.enabled || !toP.enabled)
            return (false, CODE_PROFILE_DISABLED);

        // Identity requirement per profile (only for non-exempt)
        if (
            !isExempt[from] &&
            fromP.requireIdentity &&
            (!fromOk || fromId.providerId == 0)
        ) {
            return (false, CODE_IDENTITY_MISSING_OR_INVALID);
        }
        if (
            !isExempt[to] &&
            toP.requireIdentity &&
            (!toOk || toId.providerId == 0)
        ) {
            return (false, CODE_IDENTITY_MISSING_OR_INVALID);
        }

        uint64 nowTs = uint64(block.timestamp);

        // Validate identities (if present)
        if (!isExempt[from] && fromOk && fromId.providerId != 0) {
            (bool validFrom, uint8 whyFrom) = _validateIdentity(
                fromId,
                fromP,
                nowTs
            );
            if (!validFrom) return (false, whyFrom);
        }
        if (!isExempt[to] && toOk && toId.providerId != 0) {
            (bool validTo, uint8 whyTo) = _validateIdentity(toId, toP, nowTs);
            if (!validTo) return (false, whyTo);
        }

        // Pair blocked?
        if (pairBlocked[fromJ][toJ]) return (false, CODE_PAIR_BLOCKED);

        // Same-jurisdiction constraint (either side can impose it)
        if (
            (fromP.sameJurisdictionOnly || toP.sameJurisdictionOnly) &&
            (fromJ != toJ)
        ) {
            return (false, CODE_PAIR_BLOCKED);
        }

        // Amount constraint (apply sender's policy)
        if (fromP.maxTransfer != 0 && amount > uint256(fromP.maxTransfer)) {
            return (false, CODE_AMOUNT_TOO_LARGE);
        }

        // Lockup constraint (apply to sender/outgoing)
        if (!isExempt[from] && fromP.enforceLockupOnTransfer) {
            uint64 lu = (fromOk && fromId.providerId != 0)
                ? fromId.lockupUntil
                : 0;
            if (lu != 0 && nowTs < lu) {
                return (false, CODE_LOCKED);
            }
        }

        return (true, CODE_OK);
    }

    function _effectiveProfile(
        uint16 jurisdiction
    ) internal view returns (JurisdictionProfile memory p) {
        p = _profiles[jurisdiction];
        if (!p.enabled && jurisdiction != 0) {
            JurisdictionProfile memory d = _profiles[0];
            if (d.enabled) return d;
        }
        return p;
    }

    function _validateIdentity(
        IAgriIdentityAttestationV1.Payload memory idp,
        JurisdictionProfile memory p,
        uint64 nowTs
    ) internal pure returns (bool ok, uint8 why) {
        if (idp.providerId == 0)
            return (false, CODE_IDENTITY_MISSING_OR_INVALID);

        // expiry handling
        if (idp.expiry == 0) {
            if (!p.allowNoExpiry) return (false, CODE_NO_EXPIRY_NOT_ALLOWED);
        } else {
            // ✅ más correcto: expired si now >= expiry
            if (nowTs >= idp.expiry) return (false, CODE_IDENTITY_EXPIRED);

            if (p.minTtlSeconds != 0) {
                uint256 remaining = uint256(idp.expiry) - uint256(nowTs);
                if (remaining < uint256(p.minTtlSeconds))
                    return (false, CODE_IDENTITY_TTL_TOO_LOW);
            }
        }

        // tier constraints
        if (idp.tier < p.minTier) return (false, CODE_TIER_OUT_OF_RANGE);
        if (p.maxTier != 0 && idp.tier > p.maxTier)
            return (false, CODE_TIER_OUT_OF_RANGE);

        // flags constraints
        if ((idp.flags & p.requiredFlags) != p.requiredFlags)
            return (false, CODE_FLAGS_MISMATCH);
        if ((idp.flags & p.forbiddenFlags) != 0)
            return (false, CODE_FLAGS_MISMATCH);

        return (true, CODE_OK);
    }

    function _safeIdentityOf(
        address account
    )
        internal
        view
        returns (bool ok, IAgriIdentityAttestationV1.Payload memory payload)
    {
        address ia = identityAttestation;
        if (ia == address(0)) return (false, payload);

        bytes memory cd = abi.encodeWithSelector(
            IAgriIdentityAttestationV1.identityOf.selector,
            account
        );

        (bool success, bytes memory ret) = SafeStaticCall.staticcallRaw(
            ia,
            uint256(IDENTITY_GAS_STIPEND),
            cd,
            uint256(IDENTITY_MAX_RET_BYTES)
        );

        if (!success || ret.length < uint256(IDENTITY_MIN_RET_BYTES)) {
            return (false, payload);
        }

        payload = abi.decode(ret, (IAgriIdentityAttestationV1.Payload));

        return (true, payload);
    }

    // ------------------------------ RBAC ------------------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, caller)
        ) {
            return;
        }

        revert UAgriErrors.UAgri__Unauthorized();
    }
}
