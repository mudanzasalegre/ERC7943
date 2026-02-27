// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {RoleManager} from "../access/RoleManager.sol";
import {IAgriFreezeV1} from "../interfaces/v1/IAgriFreezeV1.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

/// @notice Per-account frozen token amounts (ERC-7943 freeze storage module).
/// @dev - Freezing does NOT move balances; it only affects transfer eligibility in the share token.
///      - Implementations MAY set frozen > balance; token logic MUST treat unfrozen as 0 in that case.
///      - Views MUST be non-reverting (this contract's views do not revert).
///      - Includes optional token-only entrypoints so the ERC-7943 token can emit the normative events itself
///        without duplicating events from this module.
///
/// Roles:
/// - DEFAULT_ADMIN_ROLE: configure token binding
/// - REGULATOR_ENFORCER_ROLE: freeze/unfreeze (administrative)
contract FreezeManager is IAgriFreezeV1 {
    // --------------------------------- Errors ---------------------------------

    error FreezeManager__BadInit();
    error FreezeManager__InvalidAddress();
    error FreezeManager__Unauthorized();
    error FreezeManager__OnlyToken();
    error FreezeManager__LengthMismatch();

    // --------------------------------- Events ---------------------------------

    /// @dev Normative ERC-7943 event signature. Emitted by the module only in the direct admin methods.
    event Frozen(address indexed account, uint256 amount);

    event TokenUpdated(address indexed oldToken, address indexed newToken);

    // ------------------------------- Constants --------------------------------

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // -------------------------------- Storage --------------------------------

    RoleManager internal _roleManager;
    address public override token; // optional binding: ERC-7943 token that may call token-only methods

    mapping(address => uint256) private _frozen;
    bool private _initialized;

    // ----------------------------- Initialization -----------------------------

    constructor(address roleManager_, address token_) {
        _init(roleManager_, token_);
    }

    /// @notice Initializer for clone/proxy patterns (call once).
    function initialize(address roleManager_, address token_) external {
        if (_initialized) revert FreezeManager__BadInit();
        _init(roleManager_, token_);
    }

    function _init(address roleManager_, address token_) internal {
        if (_initialized) revert FreezeManager__BadInit();
        _initialized = true;

        if (roleManager_ == address(0)) revert FreezeManager__InvalidAddress();
        _roleManager = RoleManager(roleManager_);

        // token_ MAY be zero initially (set later), but once set it should be a real contract address
        token = token_;
        if (token_ != address(0)) emit TokenUpdated(address(0), token_);
    }

    // -------------------------------- Introspection ---------------------------

    /// @inheritdoc IAgriFreezeV1
    function roleManager() external view override returns (address) {
        return address(_roleManager);
    }

    // ---------------------------------- Views ---------------------------------

    /// @notice ERC-7943-compatible frozen amount view.
    /// @dev MUST NOT revert.
    function getFrozenTokens(address account) external view override returns (uint256) {
        return _frozen[account];
    }

    /// @notice Convenience alias.
    function frozenOf(address account) external view returns (uint256) {
        return _frozen[account];
    }

    // -------------------------- Admin configuration ---------------------------

    /// @notice Updates the bound token (optional).
    /// @dev Use a timelock/multisig in institutional profiles.
    function setToken(address newToken) external override {
        _requireDefaultAdmin();
        if (newToken == address(0)) revert FreezeManager__InvalidAddress();
        address old = token;
        token = newToken;
        emit TokenUpdated(old, newToken);
    }

    // ----------------------------- Admin actions ------------------------------

    /// @notice Sets the frozen amount for `account`.
    /// @dev Emits `Frozen`. Admin direct method (used if you want the module to be the event source).
    function setFrozenTokens(address account, uint256 frozenAmount) external override {
        _requireEnforcer();
        if (account == address(0)) revert FreezeManager__InvalidAddress();
        _setFrozen(account, frozenAmount);
        emit Frozen(account, frozenAmount);
    }

    /// @notice Batch version of setFrozenTokens.
    function setFrozenTokensBatch(address[] calldata accounts, uint256[] calldata frozenAmounts) external override {
        _requireEnforcer();
        uint256 len = accounts.length;
        if (len != frozenAmounts.length) revert FreezeManager__LengthMismatch();

        for (uint256 i; i < len; ) {
            address a = accounts[i];
            if (a == address(0)) revert FreezeManager__InvalidAddress();
            uint256 amt = frozenAmounts[i];

            _setFrozen(a, amt);
            emit Frozen(a, amt);

            unchecked { ++i; }
        }
    }

    /// @notice Increases frozen amount by `delta`.
    function increaseFrozen(address account, uint256 delta) external {
        _requireEnforcer();
        if (account == address(0)) revert FreezeManager__InvalidAddress();
        uint256 amt = _frozen[account] + delta;
        _setFrozen(account, amt);
        emit Frozen(account, amt);
    }

    /// @notice Decreases frozen amount by `delta`, floor at 0.
    function decreaseFrozen(address account, uint256 delta) external {
        _requireEnforcer();
        if (account == address(0)) revert FreezeManager__InvalidAddress();

        uint256 cur = _frozen[account];
        uint256 amt = (delta >= cur) ? 0 : (cur - delta);

        _setFrozen(account, amt);
        emit Frozen(account, amt);
    }

    // -------------------------- Token-only entrypoints ------------------------

    function setFrozenTokensFromToken(address account, uint256 frozenAmount) external override {
        _requireToken();
        if (account == address(0)) revert FreezeManager__InvalidAddress();
        _setFrozen(account, frozenAmount);
    }

    function setFrozenTokensBatchFromToken(address[] calldata accounts, uint256[] calldata frozenAmounts)
        external
        override
    {
        _requireToken();
        uint256 len = accounts.length;
        if (len != frozenAmounts.length) revert FreezeManager__LengthMismatch();

        for (uint256 i; i < len; ) {
            address a = accounts[i];
            if (a == address(0)) revert FreezeManager__InvalidAddress();
            _setFrozen(a, frozenAmounts[i]);
            unchecked { ++i; }
        }
    }

    // -------------------------------- Internals ------------------------------

    function _setFrozen(address account, uint256 amount) internal {
        _frozen[account] = amount;
    }

    function _requireDefaultAdmin() internal view {
        if (!_roleManager.hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert FreezeManager__Unauthorized();
    }

    function _requireEnforcer() internal view {
        RoleManager rm = _roleManager;
        if (!rm.hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !rm.hasRole(UAgriRoles.REGULATOR_ENFORCER_ROLE, msg.sender)) {
            revert FreezeManager__Unauthorized();
        }
    }

    function _requireToken() internal view {
        if (msg.sender != token) revert FreezeManager__OnlyToken();
    }
}
