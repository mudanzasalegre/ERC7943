// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Two-step admin ownership (standalone helper).
/// @dev Useful as a lightweight fallback admin for standalone modules / factory templates.
/// In uAgri, RoleManager is the main RBAC; this is OPTIONAL.
///
/// Semantics:
/// - `admin()` is the current admin.
/// - `pendingAdmin()` is the nominated next admin.
/// - `transferAdmin(newAdmin)` sets pending (only current admin).
/// - `acceptAdmin()` finalizes (only pending admin).
/// - `renounceAdmin()` clears admin (dangerous; consider disabling in production).
abstract contract TwoStepAdmin {
    // --------------------------------- Errors ---------------------------------

    error TwoStepAdmin__Unauthorized();
    error TwoStepAdmin__InvalidAddress();
    error TwoStepAdmin__NoPendingAdmin();

    // --------------------------------- Events ---------------------------------

    event AdminTransferStarted(address indexed previousAdmin, address indexed newPendingAdmin);
    event AdminTransferAccepted(address indexed previousAdmin, address indexed newAdmin);
    event AdminRenounced(address indexed previousAdmin);

    // -------------------------------- Storage --------------------------------

    address private _admin;
    address private _pendingAdmin;

    // ----------------------------- Initialization -----------------------------

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert TwoStepAdmin__InvalidAddress();
        _admin = initialAdmin;
        emit AdminTransferAccepted(address(0), initialAdmin);
    }

    // --------------------------------- Views ---------------------------------

    function admin() public view returns (address) {
        return _admin;
    }

    function pendingAdmin() public view returns (address) {
        return _pendingAdmin;
    }

    // ----------------------------- Admin actions ------------------------------

    function transferAdmin(address newAdmin) public {
        _requireAdmin();
        if (newAdmin == address(0)) revert TwoStepAdmin__InvalidAddress();
        _pendingAdmin = newAdmin;
        emit AdminTransferStarted(_admin, newAdmin);
    }

    function acceptAdmin() public {
        address p = _pendingAdmin;
        if (p == address(0)) revert TwoStepAdmin__NoPendingAdmin();
        if (msg.sender != p) revert TwoStepAdmin__Unauthorized();

        address old = _admin;
        _admin = p;
        _pendingAdmin = address(0);

        emit AdminTransferAccepted(old, p);
    }

    /// @notice Renounce admin (sets admin to address(0)).
    /// @dev Dangerous; prefer transferring to a timelock/multisig instead.
    function renounceAdmin() public {
        _requireAdmin();
        address old = _admin;
        _admin = address(0);
        _pendingAdmin = address(0);
        emit AdminRenounced(old);
    }

    // -------------------------------- Internals ------------------------------

    function _requireAdmin() internal view {
        if (msg.sender != _admin) revert TwoStepAdmin__Unauthorized();
    }
}
