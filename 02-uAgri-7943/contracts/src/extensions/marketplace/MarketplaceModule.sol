// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriMarketplaceV1} from "../../interfaces/v1/IAgriMarketplaceV1.sol";
import {RoleManager} from "../../access/RoleManager.sol";
import {UAgriRoles} from "../../interfaces/constants/UAgriRoles.sol";
import {UAgriErrors} from "../../interfaces/constants/UAgriErrors.sol";
import {SafeERC20} from "../../_shared/SafeERC20.sol";

/// @title MarketplaceModule
/// @notice Simple non-custodial listings: ERC20-for-ERC20 (supports uAgri share token).
contract MarketplaceModule is IAgriMarketplaceV1 {
    using SafeERC20 for address;

    // --------------------------------- Errors ---------------------------------
    error Marketplace__AlreadyInitialized();
    error Marketplace__InvalidAddress();
    error Marketplace__InvalidAmount();
    error Marketplace__NotSeller();
    error Marketplace__NotAuthorized();
    error Marketplace__NotFound();
    error Marketplace__TooMuch();
    error Marketplace__BadFee();

    // -------------------------------- Storage --------------------------------
    RoleManager public roleManager;
    bool private _initialized;

    uint256 public nextId;

    // fee on cost in buyToken
    uint16 public feeBps; // 0..10000
    address public feeRecipient;

    struct Listing {
        address seller;
        address sellToken;
        address buyToken;
        uint256 remaining;
        uint256 price; // unit price: buyToken units per 1 sellToken unit
    }

    mapping(uint256 => Listing) public listings;

    // --------------------------------- Init ----------------------------------
    constructor(address roleManager_, address feeRecipient_, uint16 feeBps_) {
        _init(roleManager_, feeRecipient_, feeBps_);
    }

    function initialize(address roleManager_, address feeRecipient_, uint16 feeBps_) external {
        _init(roleManager_, feeRecipient_, feeBps_);
    }

    function _init(address roleManager_, address feeRecipient_, uint16 feeBps_) internal {
        if (_initialized) revert Marketplace__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert Marketplace__InvalidAddress();
        roleManager = RoleManager(roleManager_);

        _setFee(feeRecipient_, feeBps_);
    }

    // ------------------------------ Admin ops ---------------------------------
    function setFee(address newRecipient, uint16 newFeeBps) external {
        _requireAdmin();
        _setFee(newRecipient, newFeeBps);
    }

    function _setFee(address newRecipient, uint16 newFeeBps) internal {
        if (newFeeBps > 10_000) revert Marketplace__BadFee();
        if (newFeeBps != 0 && newRecipient == address(0)) revert Marketplace__InvalidAddress();
        feeBps = newFeeBps;
        feeRecipient = newRecipient;
    }

    // --------------------------------- Core ----------------------------------
    function list(
        address sellToken,
        uint256 sellAmount,
        address buyToken,
        uint256 price
    ) external returns (uint256 id) {
        if (sellToken == address(0) || buyToken == address(0)) revert Marketplace__InvalidAddress();
        if (sellAmount == 0 || price == 0) revert Marketplace__InvalidAmount();

        unchecked { id = ++nextId; }

        listings[id] = Listing({
            seller: msg.sender,
            sellToken: sellToken,
            buyToken: buyToken,
            remaining: sellAmount,
            price: price
        });

        emit Listed(id, msg.sender, sellToken, sellAmount, buyToken, price);
    }

    function buy(uint256 id, uint256 amount) external {
        Listing memory l = listings[id];
        if (l.seller == address(0)) revert Marketplace__NotFound();
        if (amount == 0) revert Marketplace__InvalidAmount();
        if (amount > l.remaining) revert Marketplace__TooMuch();

        uint256 cost = amount * l.price;
        uint256 fee = (feeBps == 0) ? 0 : (cost * feeBps) / 10_000;
        uint256 net = cost - fee;

        // buyToken: buyer -> seller (+ fee)
        l.buyToken.safeTransferFrom(msg.sender, l.seller, net);
        if (fee != 0) l.buyToken.safeTransferFrom(msg.sender, feeRecipient, fee);

        // sellToken: seller -> buyer
        l.sellToken.safeTransferFrom(l.seller, msg.sender, amount);

        uint256 remaining = l.remaining - amount;
        if (remaining == 0) {
            delete listings[id];
        } else {
            listings[id].remaining = remaining;
        }

        emit Purchased(id, msg.sender, amount, cost);
    }

    function cancel(uint256 id) external {
        Listing memory l = listings[id];
        if (l.seller == address(0)) revert Marketplace__NotFound();

        if (msg.sender != l.seller) {
            _requireAdmin();
        }

        delete listings[id];
        emit Cancelled(id);
    }

    // -------------------------------- Internals ------------------------------
    function _requireAdmin() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.MARKETPLACE_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) return;

        revert Marketplace__NotAuthorized();
    }
}
