// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriDocumentRegistryV1} from "../interfaces/v1/IAgriDocumentRegistryV1.sol";
import {RoleManager} from "../access/RoleManager.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @title DocumentRegistry
/// @notice On-chain anchor of off-chain documents for auditability (hash + minimal metadata + versioning).
/// @dev Stores small metadata and version linkage; the human-readable pointer is emitted in the event.
contract DocumentRegistry is IAgriDocumentRegistryV1 {
    // --------------------------------- Errors ---------------------------------

    error DocumentRegistry__BadInit();
    error DocumentRegistry__InvalidAddress();
    error DocumentRegistry__Unauthorized();
    error DocumentRegistry__InvalidHash();
    error DocumentRegistry__InvalidIssuedAt();
    error DocumentRegistry__PointerTooLong();
    error DocumentRegistry__AlreadyRegistered(bytes32 docHash);

    // --------------------------------- Events ---------------------------------

    event RoleManagerUpdated(address indexed oldRoleManager, address indexed newRoleManager);

    // ------------------------------- Constants --------------------------------

    /// @dev Hard cap to avoid accidental gas-bombs in event data.
    uint256 public constant MAX_POINTER_BYTES = 2048;

    // -------------------------------- Storage --------------------------------

    RoleManager public roleManager;
    bool private _initialized;

    struct DocSlot {
        bytes32 campaignId;
        bytes32 plotRef;
        bytes32 lotId;
        bytes32 latestDocHash;
        uint32 docType;
        uint32 latestVersion; // starts at 0; first doc => v1
    }

    struct DocMeta {
        bytes32 docKey;      // key that groups versions (docType + refs)
        bytes32 prevHash;    // previous version docHash (0 for v1)
        bytes32 pointerHash; // keccak256(pointer)
        address issuer;
        uint64 issuedAt;
        uint32 version;
    }

    /// @dev docKey => slot metadata + latest pointers
    mapping(bytes32 => DocSlot) private _slots;

    /// @dev docKey => version => docHash
    mapping(bytes32 => mapping(uint32 => bytes32)) private _hashAtVersion;

    /// @dev docHash => metadata (docHash is the primary anchor)
    mapping(bytes32 => DocMeta) private _meta;

    // ----------------------------- Initialization -----------------------------

    constructor(address roleManager_) {
        _init(roleManager_);
    }

    /// @notice Initializer for clone/proxy patterns (call once).
    function initialize(address roleManager_) external {
        if (_initialized) revert DocumentRegistry__BadInit();
        _init(roleManager_);
    }

    function _init(address roleManager_) internal {
        if (_initialized) revert DocumentRegistry__BadInit();
        _initialized = true;

        if (roleManager_ == address(0)) revert DocumentRegistry__InvalidAddress();
        roleManager = RoleManager(roleManager_);

        emit RoleManagerUpdated(address(0), roleManager_);
    }

    // ------------------------------ Admin ops --------------------------------

    function setRoleManager(address newRoleManager) external {
        _requireGovernance();
        if (newRoleManager == address(0)) revert DocumentRegistry__InvalidAddress();
        address old = address(roleManager);
        roleManager = RoleManager(newRoleManager);
        emit RoleManagerUpdated(old, newRoleManager);
    }

    // --------------------------------- V1 API --------------------------------

    /// @inheritdoc IAgriDocumentRegistryV1
    function registerDoc(
        uint32 docType,
        bytes32 docHash,
        uint64 issuedAt,
        bytes32 campaignId,
        bytes32 plotRef,
        bytes32 lotId,
        string calldata pointer
    ) external {
        _requireRegistrar();

        if (docHash == bytes32(0)) revert DocumentRegistry__InvalidHash();
        if (issuedAt == 0) revert DocumentRegistry__InvalidIssuedAt();

        bytes memory p = bytes(pointer);
        if (p.length > MAX_POINTER_BYTES) revert DocumentRegistry__PointerTooLong();
        bytes32 pHash = keccak256(p);

        // docHash is the primary content anchor: must be globally unique.
        if (_meta[docHash].version != 0) revert DocumentRegistry__AlreadyRegistered(docHash);

        bytes32 key = docKeyOf(docType, campaignId, plotRef, lotId);
        DocSlot storage s = _slots[key];

        // First time this slot is used: store the stable refs (small, constant per slot).
        if (s.latestVersion == 0) {
            s.docType = docType;
            s.campaignId = campaignId;
            s.plotRef = plotRef;
            s.lotId = lotId;
        }

        uint32 nextVersion = s.latestVersion + 1;
        bytes32 prev = s.latestDocHash;

        s.latestVersion = nextVersion;
        s.latestDocHash = docHash;

        _hashAtVersion[key][nextVersion] = docHash;

        _meta[docHash] = DocMeta({
            docKey: key,
            prevHash: prev,
            pointerHash: pHash,
            issuer: msg.sender,
            issuedAt: issuedAt,
            version: nextVersion
        });

        emit DocRegistered(docType, docHash, msg.sender, issuedAt, campaignId, plotRef, lotId, pointer);
    }

    // --------------------------------- Views ---------------------------------

    function docKeyOf(uint32 docType, bytes32 campaignId, bytes32 plotRef, bytes32 lotId) public pure returns (bytes32) {
        return keccak256(abi.encode(docType, campaignId, plotRef, lotId));
    }

    function latestVersion(uint32 docType, bytes32 campaignId, bytes32 plotRef, bytes32 lotId) external view returns (uint32) {
        return _slots[docKeyOf(docType, campaignId, plotRef, lotId)].latestVersion;
    }

    function latestDocHash(uint32 docType, bytes32 campaignId, bytes32 plotRef, bytes32 lotId) external view returns (bytes32) {
        return _slots[docKeyOf(docType, campaignId, plotRef, lotId)].latestDocHash;
    }

    function docHashAtVersion(bytes32 docKey, uint32 version) external view returns (bytes32) {
        return _hashAtVersion[docKey][version];
    }

    /// @notice Fetch metadata by docHash (non-reverting; returns `exists=false` if unknown).
    function docInfo(bytes32 docHash)
        external
        view
        returns (
            bool exists,
            uint32 docType,
            uint32 version,
            uint64 issuedAt,
            address issuer,
            bytes32 campaignId,
            bytes32 plotRef,
            bytes32 lotId,
            bytes32 pointerHash,
            bytes32 prevHash
        )
    {
        DocMeta memory m = _meta[docHash];
        if (m.version == 0) return (false, 0, 0, 0, address(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0));

        DocSlot storage s = _slots[m.docKey];
        return (
            true,
            s.docType,
            m.version,
            m.issuedAt,
            m.issuer,
            s.campaignId,
            s.plotRef,
            s.lotId,
            m.pointerHash,
            m.prevHash
        );
    }

    // ------------------------------ RBAC -------------------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) || rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller)) return;

        revert DocumentRegistry__Unauthorized();
    }

    function _requireRegistrar() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, caller) ||
            rm.hasRole(UAgriRoles.FARM_OPERATOR_ROLE, caller) ||
            rm.hasRole(UAgriRoles.ORACLE_UPDATER_ROLE, caller) ||
            rm.hasRole(UAgriRoles.CUSTODY_ATTESTER_ROLE, caller)
        ) {
            return;
        }

        revert DocumentRegistry__Unauthorized();
    }
}