// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriTreasuryV1} from "../interfaces/v1/IAgriTreasuryV1.sol";
import {IAgriModulesV1} from "../interfaces/v1/IAgriModulesV1.sol";
import {IAgriComplianceV1} from "../interfaces/v1/IAgriComplianceV1.sol";

import {UAgriTypes} from "../interfaces/constants/UAgriTypes.sol";
import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

import {RoleManager} from "../access/RoleManager.sol";
import {ReentrancyGuard} from "../_shared/ReentrancyGuard.sol";
import {SafeERC20} from "../_shared/SafeERC20.sol";
import {SafeStaticCall} from "../_shared/SafeStaticCall.sol";

/// @dev Minimal ERC-20 interface (for balance checks only).
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/// @title CampaignTreasury
/// @notice Holds the campaign settlement asset and pays out redemptions / fees.
/// @dev Designed to be called by FundingManager (as an allowlisted spender) and by governance.
///      Optionally can enforce compliance on pay() using the campaign's compliance module (fail-closed).
contract CampaignTreasury is IAgriTreasuryV1, ReentrancyGuard {
    // ------------------------------- Events ----------------------------------

    event SpenderUpdated(address indexed spender, bool allowed);
    event ComplianceOnPayToggled(bool enabled);

    // ------------------------------- Errors ----------------------------------

    error CampaignTreasury__AlreadyInitialized();
    error CampaignTreasury__InvalidRoleManager();
    error CampaignTreasury__InvalidCampaignId();
    error CampaignTreasury__InvalidShareToken();
    error CampaignTreasury__InvalidSettlementAsset();
    error CampaignTreasury__UnauthorizedSpender();
    error CampaignTreasury__InsufficientBalance(uint256 balance, uint256 amount);

    // ------------------------------- Storage ---------------------------------

    RoleManager public roleManager;
    bytes32 public campaignId;

    /// @notice Share token for this campaign (used to resolve modules & view gas limits).
    address public shareToken;

    /// @dev Settlement asset held by this treasury.
    address private _settlementAsset;

    /// @notice Allowlisted spenders (e.g., FundingManager, Distribution modules).
    mapping(address => bool) public isSpender;

    /// @notice Optional: enforce compliance.canTransact(to) on pay() (fail-closed).
    bool public enforceComplianceOnPay;

    /// @notice Optional accounting: total inflow noted per epoch.
    mapping(uint64 => uint256) public inflowByEpoch;

    bool private _initialized;

    // -------------------------------- Modifiers ------------------------------

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    modifier onlyPayAuth() {
        _requirePayAuth();
        _;
    }

    modifier onlyReporter() {
        _requireReporter();
        _;
    }

    // ------------------------------ Init / Config ----------------------------

    constructor(
        address roleManager_,
        bytes32 campaignId_,
        address shareToken_,
        address settlementAsset_,
        address initialSpender_,
        bool enforceComplianceOnPay_
    ) {
        _init(
            roleManager_,
            campaignId_,
            shareToken_,
            settlementAsset_,
            initialSpender_,
            enforceComplianceOnPay_
        );
    }

    function initialize(
        address roleManager_,
        bytes32 campaignId_,
        address shareToken_,
        address settlementAsset_,
        address initialSpender_,
        bool enforceComplianceOnPay_
    ) external {
        _init(
            roleManager_,
            campaignId_,
            shareToken_,
            settlementAsset_,
            initialSpender_,
            enforceComplianceOnPay_
        );
    }

    function _init(
        address roleManager_,
        bytes32 campaignId_,
        address shareToken_,
        address settlementAsset_,
        address initialSpender_,
        bool enforceComplianceOnPay_
    ) internal {
        if (_initialized) revert CampaignTreasury__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert CampaignTreasury__InvalidRoleManager();
        if (campaignId_ == bytes32(0)) revert CampaignTreasury__InvalidCampaignId();
        if (shareToken_ == address(0)) revert CampaignTreasury__InvalidShareToken();
        if (settlementAsset_ == address(0)) revert CampaignTreasury__InvalidSettlementAsset();

        roleManager = RoleManager(roleManager_);
        campaignId = campaignId_;
        shareToken = shareToken_;
        _settlementAsset = settlementAsset_;

        enforceComplianceOnPay = enforceComplianceOnPay_;
        emit ComplianceOnPayToggled(enforceComplianceOnPay_);

        if (initialSpender_ != address(0)) {
            isSpender[initialSpender_] = true;
            emit SpenderUpdated(initialSpender_, true);
        }
    }

    // --------------------------- IAgriTreasuryV1 ----------------------------

    function settlementAsset() external view returns (address) {
        return _settlementAsset;
    }

    function availableBalance() external view returns (uint256) {
        // Prefer SafeERC20 helper (fails to 0 if token is weird); settlement asset should be standard ERC-20.
        return SafeERC20.balanceOf(_settlementAsset, address(this));
    }

    /// @notice Pay settlement asset to `to`.
    /// @dev Callable by allowlisted spenders or treasury/governance roles.
    ///      If enforceComplianceOnPay is enabled, requires compliance.canTransact(to) (fail-closed).
    function pay(address to, uint256 amount, bytes32 purpose)
        external
        nonReentrant
        onlyPayAuth
    {
        if (to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (amount == 0) revert UAgriErrors.UAgri__InvalidAmount();

        // Internal module payouts (to allowlisted spenders like distribution) bypass compliance checks.
        if (enforceComplianceOnPay && !isSpender[to]) {
            _requireComplianceCanTransact(to);
        }

        uint256 bal = IERC20(_settlementAsset).balanceOf(address(this));
        if (bal < amount) revert CampaignTreasury__InsufficientBalance(bal, amount);

        SafeERC20.safeTransfer(_settlementAsset, to, amount);
        emit Paid(to, amount, purpose);
    }

    /// @notice Note an inflow report (does not move funds; it’s an accounting signal).
    /// @dev Intended to be called by operators/oracles after funds are moved into the treasury.
    function noteInflow(uint64 epoch, uint256 amount, bytes32 reportHash)
        external
        onlyReporter
    {
        if (amount == 0) revert UAgriErrors.UAgri__InvalidAmount();
        inflowByEpoch[epoch] += amount;
        emit InflowNoted(epoch, amount, reportHash);
    }

    // ----------------------------- Governance API -----------------------------

    function setSpender(address spender, bool allowed) external onlyGovernance {
        if (spender == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        isSpender[spender] = allowed;
        emit SpenderUpdated(spender, allowed);
    }

    function setEnforceComplianceOnPay(bool enabled) external onlyGovernance {
        enforceComplianceOnPay = enabled;
        emit ComplianceOnPayToggled(enabled);
    }

    /// @notice Rescue any ERC-20 held by the treasury (including settlement asset).
    /// @dev Keep this restricted to governance; useful for migrations and incident response.
    function recoverERC20(address token, address to, uint256 amount)
        external
        nonReentrant
        onlyGovernance
    {
        if (token == address(0) || to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (amount == 0) revert UAgriErrors.UAgri__InvalidAmount();
        SafeERC20.safeTransfer(token, to, amount);
    }

    // ------------------------------ Internal ACL -----------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller)
        ) revert UAgriErrors.UAgri__Unauthorized();
    }

    function _requirePayAuth() internal view {
        address caller = msg.sender;

        // Allow explicit spenders (FundingManager, distribution, etc.)
        if (isSpender[caller]) return;

        // Or treasury/governance/admin roles.
        RoleManager rm = roleManager;
        if (
            rm.hasRole(UAgriRoles.TREASURY_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) return;

        revert CampaignTreasury__UnauthorizedSpender();
    }

    function _requireReporter() internal view {
        // Operators or oracle updaters can note inflows; governance/admin always allowed.
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.ORACLE_UPDATER_ROLE, caller) ||
            rm.hasRole(UAgriRoles.FARM_OPERATOR_ROLE, caller) ||
            rm.hasRole(UAgriRoles.TREASURY_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) return;

        revert UAgriErrors.UAgri__Unauthorized();
    }

    // -------------------------- Optional Compliance --------------------------

    function _requireComplianceCanTransact(address account) internal view {
        address token = shareToken;

        address compliance = IAgriModulesV1(token).complianceModule();
        if (compliance == address(0)) revert UAgriErrors.UAgri__FailClosed();

        UAgriTypes.ViewGasLimits memory g = IAgriModulesV1(token).viewGasLimits();
        (bool ok, bool allowed) = SafeStaticCall.tryStaticCallBool(
            compliance,
            uint256(g.complianceGas),
            abi.encodeWithSelector(IAgriComplianceV1.canTransact.selector, account),
            0
        );

        if (!ok) revert UAgriErrors.UAgri__FailClosed();
        if (!allowed) revert UAgriErrors.UAgri__ComplianceDenied();
    }
}
