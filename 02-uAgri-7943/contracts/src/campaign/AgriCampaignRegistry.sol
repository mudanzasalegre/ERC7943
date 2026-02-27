// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriCampaignRegistryV1} from "../interfaces/v1/IAgriCampaignRegistryV1.sol";
import {UAgriTypes} from "../interfaces/constants/UAgriTypes.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";
import {RoleManager} from "../access/RoleManager.sol";

/// @title AgriCampaignRegistry
/// @notice Registry de campañas (1 campaña = 1 token/AgriShare), con lifecycle forward-only.
/// @dev Implementa las vistas V1 (getCampaign/state) y expone admin ops no-normativas para crear/editar.
///      Pensado para ser un módulo global (multi-campaign), gobernado por RoleManager.
contract AgriCampaignRegistry is IAgriCampaignRegistryV1 {
    // ------------------------------- Storage --------------------------------

    RoleManager public roleManager;
    bool private _initialized;

    mapping(bytes32 => UAgriTypes.Campaign) private _campaigns;
    mapping(bytes32 => bool) private _exists;

    // indexación opcional (útil para UIs/scripts)
    bytes32[] private _campaignIds;
    mapping(bytes32 => uint256) private _indexPlus1; // 1-based; 0 => no existe

    // ------------------------------- Events ---------------------------------
    // (Los eventos V1 CampaignCreated / CampaignStateUpdated ya están en la interface)

    event CampaignDocsRootUpdated(bytes32 indexed campaignId, bytes32 oldRootHash, bytes32 newRootHash);
    event CampaignFundingCapUpdated(bytes32 indexed campaignId, uint256 oldCap, uint256 newCap);
    event CampaignProfileUpdated(bytes32 indexed campaignId, bytes32 oldProfile, bytes32 newProfile);
    event CampaignTimingUpdated(bytes32 indexed campaignId, uint64 oldStartTs, uint64 oldEndTs, uint64 newStartTs, uint64 newEndTs);

    event RoleManagerUpdated(address indexed oldManager, address indexed newManager);

    // -------------------------------- Errors --------------------------------

    error AgriCampaignRegistry__AlreadyInitialized();
    error AgriCampaignRegistry__InvalidRoleManager();
    error AgriCampaignRegistry__InvalidCampaignId();
    error AgriCampaignRegistry__InvalidAddress();
    error AgriCampaignRegistry__InvalidTiming(uint64 startTs, uint64 endTs);
    error AgriCampaignRegistry__Unauthorized();

    error AgriCampaignRegistry__CampaignExists(bytes32 campaignId);
    error AgriCampaignRegistry__CampaignNotFound(bytes32 campaignId);
    error AgriCampaignRegistry__InvalidStateTransition(UAgriTypes.CampaignState from, UAgriTypes.CampaignState to);
    error AgriCampaignRegistry__OnlyEditableInFunding(UAgriTypes.CampaignState current);

    // -------------------------------- Modifiers -----------------------------

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    modifier onlyOperatorOrGovernance() {
        _requireOperatorOrGovernance();
        _;
    }

    modifier onlyComplianceOrGovernance() {
        _requireComplianceOrGovernance();
        _;
    }

    // ----------------------------- Init / Configure --------------------------

    constructor(address roleManager_) {
        _init(roleManager_);
    }

    function initialize(address roleManager_) external {
        _init(roleManager_);
    }

    function _init(address roleManager_) internal {
        if (_initialized) revert AgriCampaignRegistry__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert AgriCampaignRegistry__InvalidRoleManager();
        roleManager = RoleManager(roleManager_);
    }

    /// @notice (Opcional) Permite cambiar el RoleManager (migraciones/upgrade de gobernanza).
    /// @dev Solo GOVERNANCE/DEFAULT_ADMIN.
    function setRoleManager(address newRoleManager) external onlyGovernance {
        if (newRoleManager == address(0)) revert AgriCampaignRegistry__InvalidRoleManager();
        address old = address(roleManager);
        roleManager = RoleManager(newRoleManager);
        emit RoleManagerUpdated(old, newRoleManager);
    }

    // ------------------------------ V1 Views --------------------------------

    /// @inheritdoc IAgriCampaignRegistryV1
    function getCampaign(bytes32 campaignId) external view returns (UAgriTypes.Campaign memory c) {
        if (!_exists[campaignId]) revert AgriCampaignRegistry__CampaignNotFound(campaignId);
        return _campaigns[campaignId];
    }

    /// @inheritdoc IAgriCampaignRegistryV1
    function state(bytes32 campaignId) external view returns (UAgriTypes.CampaignState) {
        if (!_exists[campaignId]) revert AgriCampaignRegistry__CampaignNotFound(campaignId);
        return _campaigns[campaignId].state;
    }

    // ------------------------- Convenience Views (non-V1) ---------------------

    function exists(bytes32 campaignId) external view returns (bool) {
        return _exists[campaignId];
    }

    function campaignCount() external view returns (uint256) {
        return _campaignIds.length;
    }

    function campaignIdAt(uint256 index) external view returns (bytes32) {
        return _campaignIds[index];
    }

    // ------------------------------- Admin Ops -------------------------------

    /// @notice Crea una campaña nueva. Estado inicial = FUNDING.
    /// @dev Solo GOVERNANCE/DEFAULT_ADMIN.
    ///      `campaign.state` se ignora; se fuerza a FUNDING.
    function createCampaign(UAgriTypes.Campaign calldata campaign) external onlyGovernance {
        bytes32 id = campaign.campaignId;
        if (id == bytes32(0)) revert AgriCampaignRegistry__InvalidCampaignId();
        if (_exists[id]) revert AgriCampaignRegistry__CampaignExists(id);

        if (campaign.settlementAsset == address(0)) revert AgriCampaignRegistry__InvalidAddress();
        _validateTiming(campaign.startTs, campaign.endTs);

        UAgriTypes.Campaign memory c = campaign;
        c.state = UAgriTypes.CampaignState.FUNDING;

        _exists[id] = true;
        _campaigns[id] = c;

        _indexPlus1[id] = _campaignIds.length + 1;
        _campaignIds.push(id);

        emit CampaignCreated(id, c.plotRef, c.settlementAsset);
        emit CampaignStateUpdated(id, c.state);
    }

    /// @notice Actualiza el estado con transición forward-only.
    /// @dev Solo GOVERNANCE/DEFAULT_ADMIN.
    function setCampaignState(bytes32 campaignId, UAgriTypes.CampaignState newState) external onlyGovernance {
        if (!_exists[campaignId]) revert AgriCampaignRegistry__CampaignNotFound(campaignId);

        UAgriTypes.Campaign storage c = _campaigns[campaignId];
        UAgriTypes.CampaignState old = c.state;

        if (newState == old) {
            // idempotente: no hace nada, pero no revierte
            return;
        }

        if (!_isForwardTransitionAllowed(old, newState)) {
            revert AgriCampaignRegistry__InvalidStateTransition(old, newState);
        }

        c.state = newState;
        emit CampaignStateUpdated(campaignId, newState);
    }

    /// @notice Actualiza docsRootHash (Merkle/IPFS root, etc.). No toca PII.
    /// @dev FARM_OPERATOR o GOVERNANCE.
    function setDocsRootHash(bytes32 campaignId, bytes32 newRootHash) external onlyOperatorOrGovernance {
        if (!_exists[campaignId]) revert AgriCampaignRegistry__CampaignNotFound(campaignId);

        UAgriTypes.Campaign storage c = _campaigns[campaignId];
        bytes32 old = c.docsRootHash;
        if (old == newRootHash) return;

        c.docsRootHash = newRootHash;
        emit CampaignDocsRootUpdated(campaignId, old, newRootHash);
    }

    /// @notice Ajusta fundingCap. Solo permitido en FUNDING.
    /// @dev GOVERNANCE.
    function setFundingCap(bytes32 campaignId, uint256 newCap) external onlyGovernance {
        if (!_exists[campaignId]) revert AgriCampaignRegistry__CampaignNotFound(campaignId);

        UAgriTypes.Campaign storage c = _campaigns[campaignId];
        if (c.state != UAgriTypes.CampaignState.FUNDING) revert AgriCampaignRegistry__OnlyEditableInFunding(c.state);

        uint256 old = c.fundingCap;
        if (old == newCap) return;

        c.fundingCap = newCap;
        emit CampaignFundingCapUpdated(campaignId, old, newCap);
    }

    /// @notice Ajusta start/end. Solo permitido en FUNDING.
    /// @dev GOVERNANCE.
    function setTiming(bytes32 campaignId, uint64 newStartTs, uint64 newEndTs) external onlyGovernance {
        if (!_exists[campaignId]) revert AgriCampaignRegistry__CampaignNotFound(campaignId);

        _validateTiming(newStartTs, newEndTs);

        UAgriTypes.Campaign storage c = _campaigns[campaignId];
        if (c.state != UAgriTypes.CampaignState.FUNDING) revert AgriCampaignRegistry__OnlyEditableInFunding(c.state);

        uint64 oldStart = c.startTs;
        uint64 oldEnd = c.endTs;

        if (oldStart == newStartTs && oldEnd == newEndTs) return;

        c.startTs = newStartTs;
        c.endTs = newEndTs;

        emit CampaignTimingUpdated(campaignId, oldStart, oldEnd, newStartTs, newEndTs);
    }

    /// @notice Ajusta jurisdictionProfile (p.ej. EU/EUDR, etc.).
    /// @dev COMPLIANCE_OFFICER o GOVERNANCE.
    function setJurisdictionProfile(bytes32 campaignId, bytes32 newProfile) external onlyComplianceOrGovernance {
        if (!_exists[campaignId]) revert AgriCampaignRegistry__CampaignNotFound(campaignId);

        UAgriTypes.Campaign storage c = _campaigns[campaignId];
        bytes32 old = c.jurisdictionProfile;

        if (old == newProfile) return;

        c.jurisdictionProfile = newProfile;
        emit CampaignProfileUpdated(campaignId, old, newProfile);
    }

    // ------------------------------ Internals --------------------------------

    function _validateTiming(uint64 startTs, uint64 endTs) internal pure {
        // Permite 0/0 (sin ventana); si endTs != 0, debe ser >= startTs (o startTs 0).
        if (endTs != 0 && startTs != 0 && endTs < startTs) {
            revert AgriCampaignRegistry__InvalidTiming(startTs, endTs);
        }
    }

    function _isForwardTransitionAllowed(
        UAgriTypes.CampaignState from,
        UAgriTypes.CampaignState to
    ) internal pure returns (bool) {
        // forward-only y explícito:
        // FUNDING -> ACTIVE -> HARVESTED -> SETTLED -> CLOSED
        // Además permitimos cierre anticipado desde cualquier estado != CLOSED.

        if (from == UAgriTypes.CampaignState.CLOSED) return false;

        if (to == UAgriTypes.CampaignState.CLOSED) {
            return true;
        }

        if (from == UAgriTypes.CampaignState.FUNDING) {
            return (to == UAgriTypes.CampaignState.ACTIVE);
        }

        if (from == UAgriTypes.CampaignState.ACTIVE) {
            return (to == UAgriTypes.CampaignState.HARVESTED);
        }

        if (from == UAgriTypes.CampaignState.HARVESTED) {
            return (to == UAgriTypes.CampaignState.SETTLED);
        }

        if (from == UAgriTypes.CampaignState.SETTLED) {
            return (to == UAgriTypes.CampaignState.CLOSED);
        }

        return false;
    }

    // ------------------------------ RBAC helpers -----------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller)
        ) revert AgriCampaignRegistry__Unauthorized();
    }

    function _requireOperatorOrGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.FARM_OPERATOR_ROLE, caller)
        ) revert AgriCampaignRegistry__Unauthorized();
    }

    function _requireComplianceOrGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, caller)
        ) revert AgriCampaignRegistry__Unauthorized();
    }
}
