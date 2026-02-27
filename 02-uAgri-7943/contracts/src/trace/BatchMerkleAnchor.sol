// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {RoleManager} from "../access/RoleManager.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @title BatchMerkleAnchor
/// @notice Anchors Merkle roots for off-chain batches (high-volume trace/doc events).
/// @dev Stores a compact record per anchor for on-chain audit queries; full batch contents stay off-chain.
contract BatchMerkleAnchor {
    error BatchMerkleAnchor__AlreadyInitialized();
    error BatchMerkleAnchor__InvalidRoleManager();
    error BatchMerkleAnchor__InvalidAddress();
    error BatchMerkleAnchor__Unauthorized();
    error BatchMerkleAnchor__InvalidRoot();
    error BatchMerkleAnchor__InvalidTimeRange();
    error BatchMerkleAnchor__AlreadyAnchored(bytes32 anchorId);

    event BatchRootAnchored(
        bytes32 indexed campaignId,
        uint32 indexed batchType,
        bytes32 root,
        uint64 fromTs,
        uint64 toTs,
        address issuer
    );

    event RoleManagerUpdated(address indexed oldRoleManager, address indexed newRoleManager);

    RoleManager public roleManager;
    bool private _initialized;

    struct Anchor {
        bytes32 root;
        uint64 fromTs;
        uint64 toTs;
        address issuer;
    }

    mapping(bytes32 => mapping(uint32 => Anchor[])) private _anchors;
    mapping(bytes32 => bool) private _anchored; // anchorId = keccak256(campaignId,batchType,root,fromTs,toTs)

    constructor(address roleManager_) { _init(roleManager_); }
    function initialize(address roleManager_) external { _init(roleManager_); }

    function _init(address roleManager_) internal {
        if (_initialized) revert BatchMerkleAnchor__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert BatchMerkleAnchor__InvalidRoleManager();
        roleManager = RoleManager(roleManager_);
        emit RoleManagerUpdated(address(0), roleManager_);
    }

    function setRoleManager(address newRoleManager) external {
        _requireGovernance();
        if (newRoleManager == address(0)) revert BatchMerkleAnchor__InvalidAddress();
        address old = address(roleManager);
        roleManager = RoleManager(newRoleManager);
        emit RoleManagerUpdated(old, newRoleManager);
    }

    function anchorRoot(
        bytes32 campaignId,
        uint32 batchType,
        bytes32 root,
        uint64 fromTs,
        uint64 toTs
    ) external {
        _requireAnchorer();

        if (root == bytes32(0)) revert BatchMerkleAnchor__InvalidRoot();
        if (toTs != 0 && fromTs != 0 && toTs < fromTs) revert BatchMerkleAnchor__InvalidTimeRange();

        bytes32 id = keccak256(abi.encode(campaignId, batchType, root, fromTs, toTs));
        if (_anchored[id]) revert BatchMerkleAnchor__AlreadyAnchored(id);
        _anchored[id] = true;

        _anchors[campaignId][batchType].push(Anchor({root: root, fromTs: fromTs, toTs: toTs, issuer: msg.sender}));
        emit BatchRootAnchored(campaignId, batchType, root, fromTs, toTs, msg.sender);
    }

    function anchored(bytes32 campaignId, uint32 batchType) external view returns (uint256) {
        return _anchors[campaignId][batchType].length;
    }

    function getAnchor(bytes32 campaignId, uint32 batchType, uint256 index) external view returns (Anchor memory) {
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
        revert BatchMerkleAnchor__Unauthorized();
    }

    function _requireAnchorer() internal view {
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

        revert BatchMerkleAnchor__Unauthorized();
    }
}
