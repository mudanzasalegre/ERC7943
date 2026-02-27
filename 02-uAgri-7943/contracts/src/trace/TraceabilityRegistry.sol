// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriTraceV1} from "../interfaces/v1/IAgriTraceV1.sol";
import {RoleManager} from "../access/RoleManager.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @title TraceabilityRegistry
/// @notice Emits traceability events and anchors Merkle roots for off-chain batches.
/// @dev Keeps on-chain storage minimal; pointers are emitted (not stored).
contract TraceabilityRegistry is IAgriTraceV1 {
    error TraceabilityRegistry__AlreadyInitialized();
    error TraceabilityRegistry__InvalidRoleManager();
    error TraceabilityRegistry__InvalidAddress();
    error TraceabilityRegistry__Unauthorized();
    error TraceabilityRegistry__InvalidDataHash();
    error TraceabilityRegistry__InvalidRoot();
    error TraceabilityRegistry__InvalidTimeRange();
    error TraceabilityRegistry__PointerTooLong();
    error TraceabilityRegistry__AlreadyAnchored(bytes32 anchorId);

    event RoleManagerUpdated(address indexed oldRoleManager, address indexed newRoleManager);

    uint256 public constant MAX_POINTER_BYTES = 2048;

    RoleManager public roleManager;
    bool private _initialized;

    struct LotHead {
        uint32 count;
        uint32 lastEventType;
        bytes32 lastDataHash;
        uint64 lastToTs;
    }

    mapping(bytes32 => LotHead) private _lotHead;

    struct RootAnchor {
        bytes32 root;
        uint64 fromTs;
        uint64 toTs;
        address issuer;
    }

    mapping(bytes32 => mapping(uint32 => RootAnchor[])) private _anchors;
    mapping(bytes32 => bool) private _anchored;

    constructor(address roleManager_) { _init(roleManager_); }
    function initialize(address roleManager_) external { _init(roleManager_); }

    function _init(address roleManager_) internal {
        if (_initialized) revert TraceabilityRegistry__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert TraceabilityRegistry__InvalidRoleManager();
        roleManager = RoleManager(roleManager_);
        emit RoleManagerUpdated(address(0), roleManager_);
    }

    function setRoleManager(address newRoleManager) external {
        _requireGovernance();
        if (newRoleManager == address(0)) revert TraceabilityRegistry__InvalidAddress();
        address old = address(roleManager);
        roleManager = RoleManager(newRoleManager);
        emit RoleManagerUpdated(old, newRoleManager);
    }

    function emitTrace(
        bytes32 campaignId,
        bytes32 plotRef,
        bytes32 lotId,
        uint32 eventType,
        bytes32 dataHash,
        uint64 fromTs,
        uint64 toTs,
        string calldata pointer
    ) external override {
        _requireTracer();

        if (dataHash == bytes32(0)) revert TraceabilityRegistry__InvalidDataHash();
        if (toTs != 0 && fromTs != 0 && toTs < fromTs) revert TraceabilityRegistry__InvalidTimeRange();

        bytes memory p = bytes(pointer);
        if (p.length > MAX_POINTER_BYTES) revert TraceabilityRegistry__PointerTooLong();

        bytes32 key = lotKeyOf(campaignId, plotRef, lotId);

        LotHead storage h = _lotHead[key];
        unchecked { h.count += 1; }
        h.lastEventType = eventType;
        h.lastDataHash = dataHash;
        h.lastToTs = toTs;

        emit TraceEvent(campaignId, plotRef, lotId, eventType, dataHash, msg.sender, fromTs, toTs, pointer);
    }

    function anchorRoot(
        bytes32 campaignId,
        uint32 batchType,
        bytes32 root,
        uint64 fromTs,
        uint64 toTs
    ) external override {
        _requireAnchorer();

        if (root == bytes32(0)) revert TraceabilityRegistry__InvalidRoot();
        if (toTs != 0 && fromTs != 0 && toTs < fromTs) revert TraceabilityRegistry__InvalidTimeRange();

        bytes32 id = keccak256(abi.encode(campaignId, batchType, root, fromTs, toTs));
        if (_anchored[id]) revert TraceabilityRegistry__AlreadyAnchored(id);
        _anchored[id] = true;

        _anchors[campaignId][batchType].push(RootAnchor({root: root, fromTs: fromTs, toTs: toTs, issuer: msg.sender}));

        emit BatchRootAnchored(campaignId, batchType, root, fromTs, toTs, msg.sender);
    }

    function lotKeyOf(bytes32 campaignId, bytes32 plotRef, bytes32 lotId) public pure returns (bytes32) {
        return keccak256(abi.encode(campaignId, plotRef, lotId));
    }

    function lotHead(bytes32 campaignId, bytes32 plotRef, bytes32 lotId) external view returns (LotHead memory) {
        return _lotHead[lotKeyOf(campaignId, plotRef, lotId)];
    }

    function anchored(bytes32 campaignId, uint32 batchType) external view returns (uint256) {
        return _anchors[campaignId][batchType].length;
    }

    function getAnchor(bytes32 campaignId, uint32 batchType, uint256 index) external view returns (RootAnchor memory) {
        return _anchors[campaignId][batchType][index];
    }

    function isAnchored(bytes32 campaignId, uint32 batchType, bytes32 root, uint64 fromTs, uint64 toTs)
        external
        view
        returns (bool)
    {
        return _anchored[keccak256(abi.encode(campaignId, batchType, root, fromTs, toTs))];
    }

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;
        if (rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) || rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller)) return;
        revert TraceabilityRegistry__Unauthorized();
    }

    function _requireTracer() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, caller) ||
            rm.hasRole(UAgriRoles.ORACLE_UPDATER_ROLE, caller) ||
            rm.hasRole(UAgriRoles.FARM_OPERATOR_ROLE, caller) ||
            rm.hasRole(UAgriRoles.CUSTODY_ATTESTER_ROLE, caller)
        ) return;

        revert TraceabilityRegistry__Unauthorized();
    }

    function _requireAnchorer() internal view {
        _requireTracer();
    }
}
