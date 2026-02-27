// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriDeliveryV1} from "../../interfaces/v1/IAgriDeliveryV1.sol";
import {IAgriComplianceV1} from "../../interfaces/v1/IAgriComplianceV1.sol";

import {RoleManager} from "../../access/RoleManager.sol";
import {UAgriRoles} from "../../interfaces/constants/UAgriRoles.sol";
import {UAgriErrors} from "../../interfaces/constants/UAgriErrors.sol";

import {AgriShareToken} from "../../core/AgriShareToken.sol";

/// @title DeliveryModule
/// @notice Burns shares and emits a receipt request for physical delivery (off-chain fulfillment).
contract DeliveryModule is IAgriDeliveryV1 {
    // --------------------------------- Errors ---------------------------------
    error Delivery__AlreadyInitialized();
    error Delivery__InvalidAddress();
    error Delivery__InvalidAmount();
    error Delivery__InvalidReceipt();
    error Delivery__InvalidLot();
    error Delivery__InvalidTerms();
    error Delivery__Unauthorized();
    error Delivery__ReceiptUsed(uint256 receiptId);

    // -------------------------------- Storage --------------------------------
    RoleManager public roleManager;
    AgriShareToken public token;

    mapping(uint256 => bool) public receiptUsed;

    bool private _initialized;

    // --------------------------------- Init ----------------------------------
    constructor(address roleManager_, address token_) {
        _init(roleManager_, token_);
    }

    function initialize(address roleManager_, address token_) external {
        _init(roleManager_, token_);
    }

    function _init(address roleManager_, address token_) internal {
        if (_initialized) revert Delivery__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0) || token_ == address(0)) revert Delivery__InvalidAddress();
        roleManager = RoleManager(roleManager_);
        token = AgriShareToken(token_);
    }

    // ------------------------------ Admin ops ---------------------------------
    function setToken(address newToken) external {
        _requireAdmin();
        if (newToken == address(0)) revert Delivery__InvalidAddress();
        token = AgriShareToken(newToken);
    }

    function setRoleManager(address newRoleManager) external {
        _requireAdmin();
        if (newRoleManager == address(0)) revert Delivery__InvalidAddress();
        roleManager = RoleManager(newRoleManager);
    }

    // --------------------------------- Core ----------------------------------
    function redeemToReceipt(
        uint256 shares,
        uint256 receiptId,
        bytes32 lotId,
        bytes32 termsHash
    ) external {
        if (shares == 0) revert Delivery__InvalidAmount();
        if (receiptId == 0) revert Delivery__InvalidReceipt();
        if (lotId == bytes32(0)) revert Delivery__InvalidLot();
        if (termsHash == bytes32(0)) revert Delivery__InvalidTerms();
        if (receiptUsed[receiptId]) revert Delivery__ReceiptUsed(receiptId);

        _requireRedeemCompliance(msg.sender);

        receiptUsed[receiptId] = true;

        // burn caller shares (module must be authorized in RoleManager for token burn)
        token.burn(msg.sender, shares);

        emit DeliveryRequested(msg.sender, shares, receiptId, lotId, termsHash);
    }

    // -------------------------------- Internals ------------------------------
    function _requireRedeemCompliance(address account) internal view {
        address comp = token.complianceModule();
        if (comp == address(0)) return;

        (bool ok, bytes memory ret) = comp.staticcall(abi.encodeCall(IAgriComplianceV1.canTransact, (account)));
        if (!ok || ret.length < 32) revert UAgriErrors.UAgri__FailClosed();
        if (!abi.decode(ret, (bool))) revert UAgriErrors.UAgri__ComplianceDenied();
    }

    function _requireAdmin() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.DELIVERY_OPERATOR_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) return;

        revert Delivery__Unauthorized();
    }
}
