// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {RoleManager} from "../access/RoleManager.sol";
import {IAgriFreezeV1} from "../interfaces/v1/IAgriFreezeV1.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @notice Authorization + canonical “unfreeze-before-forcedTransfer” math for ERC-7943 forced transfers.
/// @dev Intended flow:
/// - AgriShareToken.forcedTransfer(from,to,amount) calls `preForcedTransfer(msg.sender, from, to, amount, balanceOf(from))`
/// - Controller checks RBAC + enabled flag and returns (frozenBefore, frozenAfter)
/// - Token, if frozenAfter < frozenBefore, MUST set frozen[from]=frozenAfter (and emit Frozen(from,frozenAfter))
/// - Token executes transfer bypassing allowance/compliance/pause as per policy, and emits ForcedTransfer(from,to,amount)
///
/// Policy fixed for uAgri-7943 V1:
/// - judicial-strong: forcedTransfer bypasses canTransfer/canTransact/allowances
/// - unfreeze-before-transfer if needed so the transfer amount is transferable from “unfrozen”
contract ForcedTransferController {
    // --------------------------------- Errors ---------------------------------

    error ForcedTransferController__BadInit();
    error ForcedTransferController__InvalidAddress();
    error ForcedTransferController__Unauthorized();
    error ForcedTransferController__Disabled();
    error ForcedTransferController__OnlyToken();
    error ForcedTransferController__InvalidFromTo();
    error ForcedTransferController__InvalidAmount();
    error ForcedTransferController__InsufficientBalance(uint256 balance, uint256 amount);

    // --------------------------------- Events ---------------------------------

    event EnabledSet(bool enabled, address indexed caller);
    event TokenUpdated(address indexed oldToken, address indexed newToken);
    event FreezeModuleUpdated(address indexed oldFreeze, address indexed newFreeze);

    // ------------------------------- Constants --------------------------------

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // -------------------------------- Storage --------------------------------

    RoleManager public roleManager;
    IAgriFreezeV1 public freezeModule;

    address public token; // ERC-7943 share token allowed to call preForcedTransfer()
    bool public enabled;

    bool private _initialized;

    // ----------------------------- Initialization -----------------------------

    constructor(address roleManager_, address freezeModule_, address token_, bool enabled_) {
        _init(roleManager_, freezeModule_, token_, enabled_);
    }

    /// @notice Initializer for clone/proxy patterns (call once).
    function initialize(address roleManager_, address freezeModule_, address token_, bool enabled_) external {
        if (_initialized) revert ForcedTransferController__BadInit();
        _init(roleManager_, freezeModule_, token_, enabled_);
    }

    function _init(address roleManager_, address freezeModule_, address token_, bool enabled_) internal {
        if (_initialized) revert ForcedTransferController__BadInit();
        _initialized = true;

        if (roleManager_ == address(0) || freezeModule_ == address(0)) revert ForcedTransferController__InvalidAddress();

        roleManager = RoleManager(roleManager_);
        freezeModule = IAgriFreezeV1(freezeModule_);

        token = token_; // MAY be set later (for clones), but preForcedTransfer will require token != 0
        if (token_ != address(0)) emit TokenUpdated(address(0), token_);

        enabled = enabled_;
        emit EnabledSet(enabled_, msg.sender);
    }

    // --------------------------------- Views ----------------------------------

    /// @notice True if `actor` is authorized to initiate forced transfers (judicial strong).
    /// @dev Non-reverting view for UIs; does not imply the controller is enabled.
    function canForceTransfer(address actor) external view returns (bool) {
        RoleManager rm = roleManager;
        return rm.hasRole(DEFAULT_ADMIN_ROLE, actor) || rm.hasRole(UAgriRoles.REGULATOR_ENFORCER_ROLE, actor);
    }

    /// @notice Preview canonical freeze adjustment needed to move `amount` from `fromBalance` given current frozen.
    /// @dev Non-reverting view for UIs; does not check RBAC or enabled.
    function previewFrozenAfter(address from, uint256 amount, uint256 fromBalance)
        external
        view
        returns (uint256 frozenBefore, uint256 frozenAfter)
    {
        frozenBefore = freezeModule.getFrozenTokens(from);
        frozenAfter = _computeFrozenAfter(fromBalance, frozenBefore, amount);
    }

    // ------------------------------ Admin config ------------------------------

    /// @notice Enable/disable forced transfers globally (controller-level).
    /// @dev Typically guarded by multisig/guardian. Here: DEFAULT_ADMIN or GUARDIAN.
    function setEnabled(bool enabled_) external {
        _requireGuardianOrAdmin();
        if (enabled == enabled_) return;
        enabled = enabled_;
        emit EnabledSet(enabled_, msg.sender);
    }

    /// @notice Set the bound ERC-7943 token allowed to call preForcedTransfer().
    /// @dev Only DEFAULT_ADMIN. Recommended behind timelock/multisig.
    function setToken(address newToken) external {
        _requireAdmin();
        if (newToken == address(0)) revert ForcedTransferController__InvalidAddress();
        address old = token;
        token = newToken;
        emit TokenUpdated(old, newToken);
    }

    /// @notice Update freeze module pointer (rare; requires coordinated upgrade).
    /// @dev Only DEFAULT_ADMIN.
    function setFreezeModule(address newFreezeModule) external {
        _requireAdmin();
        if (newFreezeModule == address(0)) revert ForcedTransferController__InvalidAddress();
        address old = address(freezeModule);
        freezeModule = IAgriFreezeV1(newFreezeModule);
        emit FreezeModuleUpdated(old, newFreezeModule);
    }

    // --------------------------- Token entrypoint -----------------------------

    /// @notice Computes the required frozen adjustment (unfreeze-before-transfer) and checks authorization.
    /// @dev Called by the share token during IERC7943Fungible.forcedTransfer.
    /// @param actor The original caller of token.forcedTransfer (token passes msg.sender).
    /// @param fromBalance The current balanceOf(from) observed by token (passed to avoid extra calls here).
    /// @return frozenBefore Current frozen(from)
    /// @return frozenAfter  New frozen(from) required so that amount is transferable (<= balance - frozenAfter)
    function preForcedTransfer(
        address actor,
        address from,
        address to,
        uint256 amount,
        uint256 fromBalance
    ) external view returns (uint256 frozenBefore, uint256 frozenAfter) {
        _requireToken();
        if (!enabled) revert ForcedTransferController__Disabled();

        if (from == address(0) || to == address(0) || from == to) revert ForcedTransferController__InvalidFromTo();
        if (amount == 0) revert ForcedTransferController__InvalidAmount();

        // RBAC (judicial strong)
        RoleManager rm = roleManager;
        if (!rm.hasRole(DEFAULT_ADMIN_ROLE, actor) && !rm.hasRole(UAgriRoles.REGULATOR_ENFORCER_ROLE, actor)) {
            revert ForcedTransferController__Unauthorized();
        }

        if (fromBalance < amount) revert ForcedTransferController__InsufficientBalance(fromBalance, amount);

        frozenBefore = freezeModule.getFrozenTokens(from);
        frozenAfter = _computeFrozenAfter(fromBalance, frozenBefore, amount);
    }

    // -------------------------------- Internals --------------------------------

    function _computeFrozenAfter(uint256 balance, uint256 frozenBefore, uint256 amount) internal pure returns (uint256) {
        // Need: amount <= balance - frozenAfter  => frozenAfter <= balance - amount
        // If currently amount <= balance - frozenBefore, keep frozen unchanged.
        // Handle frozenBefore > balance as “unfrozen = 0”.
        uint256 unfrozen;
        unchecked {
            unfrozen = (frozenBefore >= balance) ? 0 : (balance - frozenBefore);
        }

        if (amount <= unfrozen) return frozenBefore;

        // Must reduce frozen down to (balance - amount) (floor at 0; balance>=amount enforced by caller)
        unchecked {
            return balance - amount;
        }
    }

    function _requireToken() internal view {
        address t = token;
        if (t == address(0) || msg.sender != t) revert ForcedTransferController__OnlyToken();
    }

    function _requireAdmin() internal view {
        if (!roleManager.hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert ForcedTransferController__Unauthorized();
    }

    function _requireGuardianOrAdmin() internal view {
        RoleManager rm = roleManager;
        if (!rm.hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !rm.hasRole(UAgriRoles.GUARDIAN_ROLE, msg.sender)) {
            revert ForcedTransferController__Unauthorized();
        }
    }
}
