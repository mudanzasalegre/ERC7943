// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";
import {RoleManager} from "../access/RoleManager.sol";

/// @dev Minimal views we need from the share token (avoid name collisions with other files).
interface IAgriShareTokenSnapshotViews {
    function roleManager() external view returns (address);
    function campaignId() external view returns (bytes32);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title SnapshotModule
/// @notice Classic ERC20Snapshot-style module implemented as an external hook receiver.
/// @dev
/// - This module is meant to be CALLED BY the share token *before* it mutates balances/supply:
///     - onTransfer(from,to,amount)  BEFORE balances update
///     - onMint(to,amount)           BEFORE totalSupply/balance update
///     - onBurn(from,amount)         BEFORE totalSupply/balance update
/// - You take a snapshot by calling snapshotEpoch(...). After that, the first time an account/supply
///   changes, we record the "pre-change" value for that snapshotId. Queries fallback to current value
///   if the account/supply hasn't changed since the snapshot.
///
/// Storage is optimized: checkpoints are packed into one uint256 slot:
///   [ snapshotId:64 | value:192 ]
/// Value must fit into uint192 (practically unlimited for ERC20 supplies).
contract SnapshotModule {
    // -------------------------------- Events --------------------------------

    event SnapshotterUpdated(address indexed account, bool allowed);
    event SnapshotCreated(uint64 indexed snapshotId, uint64 indexed epoch, bytes32 indexed reportHash);

    // -------------------------------- Errors --------------------------------

    error SnapshotModule__AlreadyInitialized();
    error SnapshotModule__InvalidRoleManager();
    error SnapshotModule__InvalidShareToken();
    error SnapshotModule__RoleManagerMismatch();
    error SnapshotModule__InvalidCampaignId();

    error SnapshotModule__UnauthorizedSnapshotter();
    error SnapshotModule__EpochAlreadySnapshotted(uint64 epoch);
    error SnapshotModule__InvalidSnapshotId(uint64 snapshotId);
    error SnapshotModule__ValueOverflow();

    // ------------------------------- Storage ---------------------------------

    RoleManager public roleManager;
    bytes32 public campaignId;
    address public shareToken;

    bool private _initialized;

    /// @notice Monotonic snapshot id (classic ERC20Snapshot behavior).
    uint64 public currentSnapshotId;

    /// @notice epoch => snapshotId (0 if none)
    mapping(uint64 => uint64) public snapshotIdByEpoch;

    /// @notice snapshotId => epoch (0 allowed)
    mapping(uint64 => uint64) public epochBySnapshotId;

    /// @notice snapshotId => reportHash (optional pointer to offchain report)
    mapping(uint64 => bytes32) public reportHashBySnapshotId;

    /// @notice Optional allowlist of snapshotters (in addition to role-based).
    mapping(address => bool) public isSnapshotter;

    /// @dev Account balance checkpoints, packed: [id|value]
    mapping(address => uint256[]) private _balanceCheckpoints;

    /// @dev Total supply checkpoints, packed: [id|value]
    uint256[] private _supplyCheckpoints;

    // -------------------------------- Modifiers -----------------------------

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    modifier onlySnapshotter() {
        _requireSnapshotter();
        _;
    }

    modifier onlyShareToken() {
        if (msg.sender != shareToken) revert UAgriErrors.UAgri__Unauthorized();
        _;
    }

    // ------------------------------ Init / Config ----------------------------

    constructor(address roleManager_, address shareToken_) {
        _init(roleManager_, shareToken_);
    }

    function initialize(address roleManager_, address shareToken_) external {
        _init(roleManager_, shareToken_);
    }

    function _init(address roleManager_, address shareToken_) internal {
        if (_initialized) revert SnapshotModule__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert SnapshotModule__InvalidRoleManager();
        if (shareToken_ == address(0)) revert SnapshotModule__InvalidShareToken();

        // Validate share token roleManager/campaignId.
        address rmOnToken = IAgriShareTokenSnapshotViews(shareToken_).roleManager();
        if (rmOnToken != roleManager_) revert SnapshotModule__RoleManagerMismatch();

        bytes32 cid = IAgriShareTokenSnapshotViews(shareToken_).campaignId();
        if (cid == bytes32(0)) revert SnapshotModule__InvalidCampaignId();

        roleManager = RoleManager(roleManager_);
        shareToken = shareToken_;
        campaignId = cid;
    }

    // ----------------------------- Governance API ----------------------------

    function setSnapshotter(address account, bool allowed) external onlyGovernance {
        if (account == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        isSnapshotter[account] = allowed;
        emit SnapshotterUpdated(account, allowed);
    }

    // ------------------------------ Snapshot API -----------------------------

    /// @notice Create a new snapshot and bind it to an epoch id (classic snapshot id increments).
    /// @dev Reverts if the epoch already has a snapshot.
    function snapshotEpoch(uint64 epoch, bytes32 reportHash) external onlySnapshotter returns (uint64 snapshotId) {
        if (snapshotIdByEpoch[epoch] != 0) revert SnapshotModule__EpochAlreadySnapshotted(epoch);

        snapshotId = ++currentSnapshotId;

        snapshotIdByEpoch[epoch] = snapshotId;
        epochBySnapshotId[snapshotId] = epoch;
        reportHashBySnapshotId[snapshotId] = reportHash;

        emit SnapshotCreated(snapshotId, epoch, reportHash);
    }

    /// @notice Balance of `account` at `snapshotId` (classic ERC20Snapshot semantics).
    function balanceOfAt(address account, uint64 snapshotId) external view returns (uint256) {
        _requireValidSnapshotId(snapshotId);

        uint256[] storage cps = _balanceCheckpoints[account];
        uint256 idx = _upperBoundById(cps, snapshotId);

        if (idx == 0) {
            // No checkpoint <= snapshotId => account never changed since snapshot => fallback current.
            return IAgriShareTokenSnapshotViews(shareToken).balanceOf(account);
        }

        return _unpackValue(cps[idx - 1]);
    }

    /// @notice Total supply at `snapshotId` (classic ERC20Snapshot semantics).
    function totalSupplyAt(uint64 snapshotId) external view returns (uint256) {
        _requireValidSnapshotId(snapshotId);

        uint256[] storage cps = _supplyCheckpoints;
        uint256 idx = _upperBoundById(cps, snapshotId);

        if (idx == 0) {
            // No checkpoint <= snapshotId => supply never changed since snapshot => fallback current.
            return IAgriShareTokenSnapshotViews(shareToken).totalSupply();
        }

        return _unpackValue(cps[idx - 1]);
    }

    /// @notice Convenience: balance at epoch (requires snapshotEpoch was called for that epoch).
    function balanceOfAtEpoch(address account, uint64 epoch) external view returns (uint256) {
        uint64 sid = snapshotIdByEpoch[epoch];
        if (sid == 0) revert SnapshotModule__InvalidSnapshotId(0);
        return this.balanceOfAt(account, sid);
    }

    /// @notice Convenience: supply at epoch (requires snapshotEpoch was called for that epoch).
    function totalSupplyAtEpoch(uint64 epoch) external view returns (uint256) {
        uint64 sid = snapshotIdByEpoch[epoch];
        if (sid == 0) revert SnapshotModule__InvalidSnapshotId(0);
        return this.totalSupplyAt(sid);
    }

    // ------------------------------ Token Hooks ------------------------------
    // Called by the share token BEFORE it mutates state.

    function onMint(address to, uint256 /*amount*/) external onlyShareToken {
        if (to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        _updateAccountCheckpoint(to);
        _updateSupplyCheckpoint();
    }

    function onBurn(address from, uint256 /*amount*/) external onlyShareToken {
        if (from == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        _updateAccountCheckpoint(from);
        _updateSupplyCheckpoint();
    }

    function onTransfer(address from, address to, uint256 /*amount*/) external onlyShareToken {
        if (from == address(0) || to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        _updateAccountCheckpoint(from);
        _updateAccountCheckpoint(to);
        // supply unchanged
    }

    // ------------------------------ Internals --------------------------------

    function _updateAccountCheckpoint(address account) internal {
        uint64 sid = currentSnapshotId;
        if (sid == 0) return;

        uint256[] storage cps = _balanceCheckpoints[account];
        uint256 len = cps.length;

        // Only write once per snapshotId (classic behavior).
        if (len == 0 || _unpackId(cps[len - 1]) < sid) {
            uint256 bal = IAgriShareTokenSnapshotViews(shareToken).balanceOf(account);
            cps.push(_pack(sid, bal));
        }
    }

    function _updateSupplyCheckpoint() internal {
        uint64 sid = currentSnapshotId;
        if (sid == 0) return;

        uint256[] storage cps = _supplyCheckpoints;
        uint256 len = cps.length;

        if (len == 0 || _unpackId(cps[len - 1]) < sid) {
            uint256 supply = IAgriShareTokenSnapshotViews(shareToken).totalSupply();
            cps.push(_pack(sid, supply));
        }
    }

    function _requireValidSnapshotId(uint64 snapshotId) internal view {
        if (snapshotId == 0 || snapshotId > currentSnapshotId) revert SnapshotModule__InvalidSnapshotId(snapshotId);
    }

    // ------------------------------ RBAC helpers -----------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller)
        ) revert UAgriErrors.UAgri__Unauthorized();
    }

    function _requireSnapshotter() internal view {
        address caller = msg.sender;

        // Explicit allowlist first.
        if (isSnapshotter[caller]) return;

        // Or oracle/operator/treasury/admin/governance.
        RoleManager rm = roleManager;
        if (
            rm.hasRole(UAgriRoles.ORACLE_UPDATER_ROLE, caller) ||
            rm.hasRole(UAgriRoles.FARM_OPERATOR_ROLE, caller) ||
            rm.hasRole(UAgriRoles.TREASURY_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) return;

        revert SnapshotModule__UnauthorizedSnapshotter();
    }

    // --------------------------- Packed checkpoints --------------------------

    /// @dev pack: [ snapshotId:64 | value:192 ]
    function _pack(uint64 snapshotId, uint256 value) internal pure returns (uint256) {
        if (value > type(uint192).max) revert SnapshotModule__ValueOverflow();
        return (uint256(snapshotId) << 192) | uint256(uint192(value));
    }

    function _unpackId(uint256 packed) internal pure returns (uint64) {
        return uint64(packed >> 192);
    }

    function _unpackValue(uint256 packed) internal pure returns (uint256) {
        return uint256(uint192(packed));
    }

    /// @dev Upper bound on checkpoint ids (first index with id > snapshotId).
    function _upperBoundById(uint256[] storage cps, uint64 snapshotId) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = cps.length;

        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (_unpackId(cps[mid]) > snapshotId) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return low;
    }
}
