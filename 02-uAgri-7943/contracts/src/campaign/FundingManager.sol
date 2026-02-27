// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriModulesV1} from "../interfaces/v1/IAgriModulesV1.sol";
import {IAgriCampaignRegistryV1} from "../interfaces/v1/IAgriCampaignRegistryV1.sol";
import {IAgriComplianceV1} from "../interfaces/v1/IAgriComplianceV1.sol";
import {IAgriDisasterV1} from "../interfaces/v1/IAgriDisasterV1.sol";
import {IAgriCustodyV1} from "../interfaces/v1/IAgriCustodyV1.sol";
import {IAgriTreasuryV1} from "../interfaces/v1/IAgriTreasuryV1.sol";
import {ISettlementQueueV1} from "../interfaces/v1/ISettlementQueueV1.sol";

import {UAgriTypes} from "../interfaces/constants/UAgriTypes.sol";
import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriFlags} from "../interfaces/constants/UAgriFlags.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

import {RoleManager} from "../access/RoleManager.sol";
import {ReentrancyGuard} from "../_shared/ReentrancyGuard.sol";
import {SafeERC20} from "../_shared/SafeERC20.sol";
import {SafeStaticCall} from "../_shared/SafeStaticCall.sol";

/// @dev Minimal ERC-20 metadata probe.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @dev Minimal ops interface implemented by AgriShareToken.
interface IAgriShareOps {
    function decimals() external view returns (uint8);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @title FundingManager
/// @notice Processes funding (deposits) and redemptions for a single campaign.
/// @dev Intended to be called by a SettlementQueue (requests) and/or by operators (instant-mode).
///      Uses fail-closed staticcalls for policy modules (disaster/compliance/custody).
contract FundingManager is ReentrancyGuard {
    // ------------------------------- Events ----------------------------------

    event SettlementQueueUpdated(address indexed queue);
    event FeesUpdated(uint16 depositFeeBps, uint16 redeemFeeBps, address indexed feeRecipient);
    event PolicyTogglesUpdated(
        bool allowDepositsWhenActive,
        bool allowRedeemsDuringFunding,
        bool enforceCustodyFreshOnRedeem
    );

    event SettlementAssetRefreshed(address indexed settlementAsset, uint8 assetDecimals, uint8 shareDecimals);

    event DepositSettled(
        address indexed payer,
        address indexed beneficiary,
        uint256 assetsIn,
        uint256 feeAssets,
        uint256 sharesOut,
        bytes32 indexed ref
    );

    event RedeemSettled(
        address indexed owner,
        address indexed beneficiary,
        uint256 sharesIn,
        uint256 assetsOut,
        uint256 feeAssets,
        bytes32 indexed ref
    );

    // ------------------------------- Errors ----------------------------------

    error FundingManager__AlreadyInitialized();
    error FundingManager__InvalidConfig();
    error FundingManager__InvalidRoleManager();
    error FundingManager__InvalidCampaignId();
    error FundingManager__InvalidShareToken();
    error FundingManager__InvalidRegistry();
    error FundingManager__InvalidSettlementAsset();
    error FundingManager__InvalidTreasury();
    error FundingManager__InvalidSettlementQueue();

    error FundingManager__MinOutNotMet(uint256 outAmount, uint256 minOut);
    error FundingManager__MaxInExceeded(uint256 inAmount, uint256 maxIn);
    error FundingManager__CapExceeded(uint256 cap, uint256 newTotalRaised);

    error FundingManager__RequestAlreadySettled(uint256 requestId);
    error FundingManager__InvalidRef();

    // ------------------------------- Storage ---------------------------------

    RoleManager public roleManager;
    bytes32 public campaignId;

    /// @notice Campaign share token (AgriShareToken).
    address public shareToken;

    /// @notice Campaign registry (source of lifecycle state and funding cap).
    IAgriCampaignRegistryV1 public registry;

    /// @notice Optional queue used for request intake.
    address public settlementQueue;

    /// @notice Cached settlement asset (read from treasury at init/refresh).
    address public settlementAsset;

    /// @notice Decimal normalization units (10**decimals).
    uint256 private _assetUnit;
    uint256 private _shareUnit;

    /// @notice Total net assets raised toward the cap (excludes deposit fees).
    uint256 public totalRaisedNet;

    /// @notice Fee configuration (basis points, 10_000 = 100%).
    uint16 public depositFeeBps;
    uint16 public redeemFeeBps;
    address public feeRecipient;

    /// @notice Lifecycle/policy toggles.
    bool public allowDepositsWhenActive;
    bool public allowRedeemsDuringFunding;
    bool public enforceCustodyFreshOnRedeem;

    /// @notice Safety: prevent settling the same queue requestId twice.
    mapping(uint256 => bool) public settledFromQueue;

    /// @notice Idempotency guard for sponsored on-ramp deposits.
    mapping(bytes32 => bool) public usedSponsoredDepositRef;

    bool private _initialized;

    // -------------------------------- Modifiers ------------------------------

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    modifier onlyProcessor() {
        // If the queue calls, allow. Otherwise require operator/treasury/admin roles.
        if (msg.sender != settlementQueue) {
            _requireOperatorOrTreasury();
        }
        _;
    }

    // ------------------------------ Init / Config ----------------------------

    constructor(
        address roleManager_,
        bytes32 campaignId_,
        address shareToken_,
        address registry_,
        address settlementQueue_,
        uint16 depositFeeBps_,
        uint16 redeemFeeBps_,
        address feeRecipient_,
        bool allowDepositsWhenActive_,
        bool allowRedeemsDuringFunding_,
        bool enforceCustodyFreshOnRedeem_
    ) {
        _init(
            roleManager_,
            campaignId_,
            shareToken_,
            registry_,
            settlementQueue_,
            depositFeeBps_,
            redeemFeeBps_,
            feeRecipient_,
            allowDepositsWhenActive_,
            allowRedeemsDuringFunding_,
            enforceCustodyFreshOnRedeem_
        );
    }

    function initialize(
        address roleManager_,
        bytes32 campaignId_,
        address shareToken_,
        address registry_,
        address settlementQueue_,
        uint16 depositFeeBps_,
        uint16 redeemFeeBps_,
        address feeRecipient_,
        bool allowDepositsWhenActive_,
        bool allowRedeemsDuringFunding_,
        bool enforceCustodyFreshOnRedeem_
    ) external {
        _init(
            roleManager_,
            campaignId_,
            shareToken_,
            registry_,
            settlementQueue_,
            depositFeeBps_,
            redeemFeeBps_,
            feeRecipient_,
            allowDepositsWhenActive_,
            allowRedeemsDuringFunding_,
            enforceCustodyFreshOnRedeem_
        );
    }

    function _init(
        address roleManager_,
        bytes32 campaignId_,
        address shareToken_,
        address registry_,
        address settlementQueue_,
        uint16 depositFeeBps_,
        uint16 redeemFeeBps_,
        address feeRecipient_,
        bool allowDepositsWhenActive_,
        bool allowRedeemsDuringFunding_,
        bool enforceCustodyFreshOnRedeem_
    ) internal {
        if (_initialized) revert FundingManager__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert FundingManager__InvalidRoleManager();
        if (campaignId_ == bytes32(0)) revert FundingManager__InvalidCampaignId();
        if (shareToken_ == address(0)) revert FundingManager__InvalidShareToken();
        if (registry_ == address(0)) revert FundingManager__InvalidRegistry();

        if (depositFeeBps_ >= 10_000 || redeemFeeBps_ >= 10_000) revert FundingManager__InvalidConfig();
        if ((depositFeeBps_ != 0 || redeemFeeBps_ != 0) && feeRecipient_ == address(0)) {
            revert FundingManager__InvalidConfig();
        }

        roleManager = RoleManager(roleManager_);
        campaignId = campaignId_;

        shareToken = shareToken_;
        registry = IAgriCampaignRegistryV1(registry_);
        settlementQueue = settlementQueue_;

        depositFeeBps = depositFeeBps_;
        redeemFeeBps = redeemFeeBps_;
        feeRecipient = feeRecipient_;

        allowDepositsWhenActive = allowDepositsWhenActive_;
        allowRedeemsDuringFunding = allowRedeemsDuringFunding_;
        enforceCustodyFreshOnRedeem = enforceCustodyFreshOnRedeem_;

        _refreshSettlementAssetAndUnits();

        emit SettlementQueueUpdated(settlementQueue_);
        emit FeesUpdated(depositFeeBps_, redeemFeeBps_, feeRecipient_);
        emit PolicyTogglesUpdated(allowDepositsWhenActive_, allowRedeemsDuringFunding_, enforceCustodyFreshOnRedeem_);
    }

    // ------------------------------ Governance --------------------------------

    function setSettlementQueue(address queue) external onlyGovernance {
        settlementQueue = queue;
        emit SettlementQueueUpdated(queue);
    }

    function setFees(uint16 depositFeeBps_, uint16 redeemFeeBps_, address feeRecipient_) external onlyGovernance {
        if (depositFeeBps_ >= 10_000 || redeemFeeBps_ >= 10_000) revert FundingManager__InvalidConfig();
        if ((depositFeeBps_ != 0 || redeemFeeBps_ != 0) && feeRecipient_ == address(0)) revert FundingManager__InvalidConfig();
        depositFeeBps = depositFeeBps_;
        redeemFeeBps = redeemFeeBps_;
        feeRecipient = feeRecipient_;
        emit FeesUpdated(depositFeeBps_, redeemFeeBps_, feeRecipient_);
    }

    function setPolicyToggles(
        bool allowDepositsWhenActive_,
        bool allowRedeemsDuringFunding_,
        bool enforceCustodyFreshOnRedeem_
    ) external onlyGovernance {
        allowDepositsWhenActive = allowDepositsWhenActive_;
        allowRedeemsDuringFunding = allowRedeemsDuringFunding_;
        enforceCustodyFreshOnRedeem = enforceCustodyFreshOnRedeem_;
        emit PolicyTogglesUpdated(allowDepositsWhenActive_, allowRedeemsDuringFunding_, enforceCustodyFreshOnRedeem_);
    }

    /// @notice Re-reads treasury.settlementAsset() and recomputes decimal units.
    /// @dev Útil si cambias treasury o settlementAsset en una migración.
    function refreshSettlementAssetAndUnits() external onlyGovernance {
        _refreshSettlementAssetAndUnits();
    }

    // ------------------------------ User wrappers -----------------------------

    function requestDeposit(uint256 amountIn, uint256 maxIn, uint64 deadline) external returns (uint256 requestId) {
        address q = settlementQueue;
        if (q == address(0)) revert FundingManager__InvalidSettlementQueue();
        return ISettlementQueueV1(q).requestDeposit(amountIn, maxIn, deadline);
    }

    function requestRedeem(uint256 sharesIn, uint256 minOut, uint64 deadline) external returns (uint256 requestId) {
        address q = settlementQueue;
        if (q == address(0)) revert FundingManager__InvalidSettlementQueue();
        return ISettlementQueueV1(q).requestRedeem(sharesIn, minOut, deadline);
    }

    // ------------------------------ Settlement API ----------------------------

    /// @notice Settle a request by pulling its data from the settlement queue.
    /// @dev Returns outAmount for RequestProcessed (sharesOut for deposit, assetsOut for redeem).
    function settleFromQueue(uint256 requestId, bytes32 ref)
        external
        nonReentrant
        onlyProcessor
        returns (uint256 outAmount)
    {
        address q = settlementQueue;
        if (q == address(0)) revert FundingManager__InvalidSettlementQueue();

        // hard safety: never settle same id twice
        if (settledFromQueue[requestId]) revert FundingManager__RequestAlreadySettled(requestId);
        settledFromQueue[requestId] = true;

        UAgriTypes.Request memory r = ISettlementQueueV1(q).getRequest(requestId);

        // Permit “Requested” (ideal) and tolerate “Processed” (si tu queue marca antes de llamar).
        if (
            r.status != UAgriTypes.RequestStatus.Requested &&
            r.status != UAgriTypes.RequestStatus.Processed
        ) revert UAgriErrors.UAgri__BadState();

        if (r.deadline != 0 && uint64(block.timestamp) > r.deadline) revert UAgriErrors.UAgri__DeadlineExpired();

        if (r.kind == UAgriTypes.RequestKind.Deposit) {
            // Dual-mode:
            // - If r.maxIn != 0 => exact shares out (r.amount = sharesDesired, r.maxIn = maxAssetsIn)
            // - Else            => exact assets in (r.amount = assetsIn, r.minOut = minSharesOut)
            if (r.maxIn != 0) {
                outAmount = _settleDepositExactShares(r.account, r.amount, r.maxIn, ref);
            } else {
                outAmount = _settleDepositExactAssets(r.account, r.amount, r.minOut, ref);
            }
            return outAmount;
        }

        if (r.kind == UAgriTypes.RequestKind.Redeem) {
            // Dual-mode:
            // - If r.maxIn != 0 => exact assets out (r.amount = assetsDesired, r.maxIn = maxSharesIn)
            // - Else            => exact shares in (r.amount = sharesIn, r.minOut = minAssetsOut)
            if (r.maxIn != 0) {
                outAmount = _settleRedeemExactAssets(r.account, r.amount, r.maxIn, ref);
            } else {
                outAmount = _settleRedeemExactShares(r.account, r.amount, r.minOut, ref);
            }
            return outAmount;
        }

        revert UAgriErrors.UAgri__InvalidAmount();
    }

    /// @notice Instant-mode: settle a deposit where the caller provides parameters (operator path).
    function settleDepositExactAssets(
        address beneficiary,
        uint256 assetsIn,
        uint256 minSharesOut,
        uint64 deadline,
        bytes32 ref
    ) external nonReentrant onlyProcessor returns (uint256 sharesOut) {
        if (deadline != 0 && uint64(block.timestamp) > deadline) revert UAgriErrors.UAgri__DeadlineExpired();
        return _settleDepositExactAssets(beneficiary, assetsIn, minSharesOut, ref);
    }

    /// @notice Instant-mode: settle a redeem where the caller provides parameters (operator path).
    function settleRedeemExactShares(
        address beneficiary,
        uint256 sharesIn,
        uint256 minAssetsOut,
        uint64 deadline,
        bytes32 ref
    ) external nonReentrant onlyProcessor returns (uint256 assetsOut) {
        if (deadline != 0 && uint64(block.timestamp) > deadline) revert UAgriErrors.UAgri__DeadlineExpired();
        return _settleRedeemExactShares(beneficiary, sharesIn, minAssetsOut, ref);
    }

    /// @notice User-facing instant deposit (no queue): transfers settlement assets from msg.sender and mints shares to msg.sender.
    function depositInstant(
        uint256 assetsIn,
        uint256 minSharesOut,
        uint64 deadline,
        bytes32 ref
    ) external nonReentrant returns (uint256 sharesOut) {
        if (deadline != 0 && uint64(block.timestamp) > deadline) revert UAgriErrors.UAgri__DeadlineExpired();
        return _settleDepositExactAssets(msg.sender, assetsIn, minSharesOut, ref);
    }

    /// @notice Sponsored instant deposit: pulls assets from `payer` and mints shares to `beneficiary`.
    /// @dev Requires ONRAMP operator-style authorization and a non-zero unique `ref`.
    function settleDepositExactAssetsFrom(
        address payer,
        address beneficiary,
        uint256 assetsIn,
        uint256 minSharesOut,
        uint64 deadline,
        bytes32 ref
    ) external nonReentrant returns (uint256 sharesOut) {
        _requireOnRampDepositOperator();

        if (payer == address(0) || beneficiary == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (ref == bytes32(0)) revert FundingManager__InvalidRef();
        if (usedSponsoredDepositRef[ref]) revert UAgriErrors.UAgri__Replay();
        if (deadline != 0 && uint64(block.timestamp) > deadline) revert UAgriErrors.UAgri__DeadlineExpired();

        // Mark before external transfers to guard webhook retries and logical reentrancy.
        usedSponsoredDepositRef[ref] = true;

        return _settleDepositExactAssetsFrom(payer, beneficiary, assetsIn, minSharesOut, ref);
    }

    /// @notice User-facing instant redeem (no queue): burns shares from msg.sender and pays settlement assets to msg.sender.
    function redeemInstant(
        uint256 sharesIn,
        uint256 minAssetsOut,
        uint64 deadline,
        bytes32 ref
    ) external nonReentrant returns (uint256 assetsOut) {
        if (deadline != 0 && uint64(block.timestamp) > deadline) revert UAgriErrors.UAgri__DeadlineExpired();
        return _settleRedeemExactShares(msg.sender, sharesIn, minAssetsOut, ref);
    }

    // ------------------------------ Previews ----------------------------------

    function previewDepositExactAssets(uint256 assetsIn) external view returns (uint256 sharesOut, uint256 feeAssets) {
        if (assetsIn == 0) return (0, 0);
        feeAssets = _fee(assetsIn, depositFeeBps);
        uint256 netAssets = assetsIn - feeAssets;
        sharesOut = _assetsToShares(netAssets);
    }

    function previewRedeemExactShares(uint256 sharesIn) external view returns (uint256 assetsOut, uint256 feeAssets) {
        if (sharesIn == 0) return (0, 0);
        uint256 grossAssets = _sharesToAssets(sharesIn);
        feeAssets = _fee(grossAssets, redeemFeeBps);
        assetsOut = grossAssets - feeAssets;
    }

    // ------------------------------ Internal settle ---------------------------

    function _settleDepositExactAssets(
        address beneficiary,
        uint256 assetsIn,
        uint256 minSharesOut,
        bytes32 ref
    ) internal returns (uint256 sharesOut) {
        return _settleDepositExactAssetsFrom(beneficiary, beneficiary, assetsIn, minSharesOut, ref);
    }

    function _settleDepositExactAssetsFrom(
        address payer,
        address beneficiary,
        uint256 assetsIn,
        uint256 minSharesOut,
        bytes32 ref
    ) internal returns (uint256 sharesOut) {
        if (payer == address(0) || beneficiary == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (assetsIn == 0) revert UAgriErrors.UAgri__InvalidAmount();

        _requireFundingOpen();
        _requireFundingNotPaused();
        _requireNotRestrictedOrFrozen();
        _requireCompliance(beneficiary);

        // Cap check uses NET assets (after fee) that go to treasury.
        uint256 feeAssets = _fee(assetsIn, depositFeeBps);
        uint256 netAssets = assetsIn - feeAssets;

        _checkCap(netAssets);

        sharesOut = _assetsToShares(netAssets);
        if (sharesOut < minSharesOut) revert FundingManager__MinOutNotMet(sharesOut, minSharesOut);

        // Move funds from payer and mint to beneficiary.
        _collectDepositFunds(payer, assetsIn, feeAssets);
        IAgriShareOps(shareToken).mint(beneficiary, sharesOut);

        totalRaisedNet += netAssets;

        emit DepositSettled(payer, beneficiary, assetsIn, feeAssets, sharesOut, ref);
    }

    function _settleDepositExactShares(
        address beneficiary,
        uint256 sharesDesired,
        uint256 maxAssetsIn,
        bytes32 ref
    ) internal returns (uint256 sharesOut) {
        if (beneficiary == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (sharesDesired == 0) revert UAgriErrors.UAgri__InvalidAmount();
        if (maxAssetsIn == 0) revert UAgriErrors.UAgri__InvalidAmount();

        _requireFundingOpen();
        _requireFundingNotPaused();
        _requireNotRestrictedOrFrozen();
        _requireCompliance(beneficiary);

        // Compute net assets required for the desired shares (rounding up).
        uint256 netAssetsNeeded = _sharesToAssetsRoundUp(sharesDesired);

        // Convert net->gross by inverting the fee: gross = ceil(net * 10_000 / (10_000 - feeBps)).
        uint256 grossAssets = netAssetsNeeded;
        uint256 feeAssets = 0;
        if (depositFeeBps != 0) {
            grossAssets = _mulDivRoundingUp(netAssetsNeeded, 10_000, 10_000 - depositFeeBps);
            feeAssets = grossAssets - netAssetsNeeded;
        }
        if (grossAssets > maxAssetsIn) revert FundingManager__MaxInExceeded(grossAssets, maxAssetsIn);

        _checkCap(netAssetsNeeded);

        // Collect funds and mint EXACT sharesDesired.
        _collectDepositFunds(beneficiary, grossAssets, feeAssets);
        IAgriShareOps(shareToken).mint(beneficiary, sharesDesired);

        totalRaisedNet += netAssetsNeeded;
        sharesOut = sharesDesired;

        emit DepositSettled(beneficiary, beneficiary, grossAssets, feeAssets, sharesOut, ref);
    }

    function _settleRedeemExactShares(
        address beneficiary,
        uint256 sharesIn,
        uint256 minAssetsOut,
        bytes32 ref
    ) internal returns (uint256 assetsOut) {
        if (beneficiary == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (sharesIn == 0) revert UAgriErrors.UAgri__InvalidAmount();

        _requireRedeemOpen();
        _requireRedeemNotPaused();
        _requireNotRestrictedOrFrozen();
        _requireCompliance(beneficiary);
        _requireCustodyFreshIfEnabled();

        uint256 grossAssets = _sharesToAssets(sharesIn);
        uint256 feeAssets = _fee(grossAssets, redeemFeeBps);
        assetsOut = grossAssets - feeAssets;

        if (assetsOut < minAssetsOut) revert FundingManager__MinOutNotMet(assetsOut, minAssetsOut);

        // Burn shares (manager must have proper role on the token).
        IAgriShareOps(shareToken).burn(beneficiary, sharesIn);

        // Pay out from treasury (purpose = ref).
        _payFromTreasury(beneficiary, assetsOut, feeAssets, ref);

        emit RedeemSettled(beneficiary, beneficiary, sharesIn, assetsOut, feeAssets, ref);
    }

    function _settleRedeemExactAssets(
        address beneficiary,
        uint256 assetsDesired,
        uint256 maxSharesIn,
        bytes32 ref
    ) internal returns (uint256 assetsOut) {
        if (beneficiary == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (assetsDesired == 0) revert UAgriErrors.UAgri__InvalidAmount();
        if (maxSharesIn == 0) revert UAgriErrors.UAgri__InvalidAmount();

        _requireRedeemOpen();
        _requireRedeemNotPaused();
        _requireNotRestrictedOrFrozen();
        _requireCompliance(beneficiary);
        _requireCustodyFreshIfEnabled();

        // Convert desired net assets to gross (pre-fee) assets required.
        uint256 grossAssets = assetsDesired;
        uint256 feeAssets = 0;
        if (redeemFeeBps != 0) {
            grossAssets = _mulDivRoundingUp(assetsDesired, 10_000, 10_000 - redeemFeeBps);
            feeAssets = grossAssets - assetsDesired;
        }

        // Compute shares required for gross assets (rounding up).
        uint256 sharesNeeded = _assetsToSharesRoundUp(grossAssets);
        if (sharesNeeded > maxSharesIn) revert FundingManager__MaxInExceeded(sharesNeeded, maxSharesIn);

        // Burn shares and pay exact assetsDesired (net) to beneficiary.
        IAgriShareOps(shareToken).burn(beneficiary, sharesNeeded);
        _payFromTreasury(beneficiary, assetsDesired, feeAssets, ref);

        assetsOut = assetsDesired;

        emit RedeemSettled(beneficiary, beneficiary, sharesNeeded, assetsOut, feeAssets, ref);
    }

    // ------------------------------ Funds movement ----------------------------

    function _collectDepositFunds(address payer, uint256 grossAssets, uint256 feeAssets) internal {
        address treasury_ = IAgriModulesV1(shareToken).treasury();
        if (treasury_ == address(0)) revert FundingManager__InvalidTreasury();

        address asset = settlementAsset;

        // net goes to treasury, fee goes to feeRecipient (or treasury if same).
        uint256 netAssets = grossAssets - feeAssets;

        if (feeAssets != 0 && feeRecipient != treasury_) {
            SafeERC20.safeTransferFrom(asset, payer, feeRecipient, feeAssets);
        }

        SafeERC20.safeTransferFrom(asset, payer, treasury_, netAssets);

        // If feeRecipient == treasury_, also transfer the fee to treasury.
        if (feeAssets != 0 && feeRecipient == treasury_) {
            SafeERC20.safeTransferFrom(asset, payer, treasury_, feeAssets);
        }
    }

    /// @dev Treasury pays are 3 args: pay(to, amount, purpose). We use `ref` as purpose.
    function _payFromTreasury(address to, uint256 assetsOut, uint256 feeAssets, bytes32 ref) internal {
        address treasury_ = IAgriModulesV1(shareToken).treasury();
        if (treasury_ == address(0)) revert FundingManager__InvalidTreasury();

        IAgriTreasuryV1(treasury_).pay(to, assetsOut, ref);

        if (feeAssets != 0) {
            address fr = feeRecipient;
            if (fr == address(0)) revert FundingManager__InvalidConfig();
            IAgriTreasuryV1(treasury_).pay(fr, feeAssets, ref);
        }
    }

    // ------------------------------ Policy checks -----------------------------

    function _requireFundingOpen() internal view {
        UAgriTypes.CampaignState st = registry.state(campaignId);
        if (st == UAgriTypes.CampaignState.FUNDING) return;
        if (allowDepositsWhenActive && st == UAgriTypes.CampaignState.ACTIVE) return;
        revert UAgriErrors.UAgri__BadState();
    }

    function _requireRedeemOpen() internal view {
        UAgriTypes.CampaignState st = registry.state(campaignId);
        if (st == UAgriTypes.CampaignState.CLOSED) revert UAgriErrors.UAgri__BadState();
        if (st == UAgriTypes.CampaignState.FUNDING && !allowRedeemsDuringFunding) revert UAgriErrors.UAgri__BadState();
        // Allow in ACTIVE/HARVESTED/SETTLED by default.
    }

    function _requireFundingNotPaused() internal view {
        (bool ok, uint256 flags) = _safeCampaignFlags();
        if (!ok) revert UAgriErrors.UAgri__FailClosed();
        if ((flags & UAgriFlags.PAUSE_FUNDING) != 0) revert UAgriErrors.UAgri__Paused();
    }

    function _requireRedeemNotPaused() internal view {
        (bool ok, uint256 flags) = _safeCampaignFlags();
        if (!ok) revert UAgriErrors.UAgri__FailClosed();
        if ((flags & UAgriFlags.PAUSE_REDEMPTIONS) != 0) revert UAgriErrors.UAgri__Paused();
    }

    function _requireNotRestrictedOrFrozen() internal view {
        // Restricted => deny; HardFrozen => deny. Fail-closed if module call fails.
        if (_safeIsRestrictedOrFailClosed()) revert UAgriErrors.UAgri__Restricted();
        if (_safeIsHardFrozenOrFailClosed()) revert UAgriErrors.UAgri__HardFrozen();
    }

    function _requireCompliance(address account) internal view {
        if (!_safeComplianceCanTransact(account)) revert UAgriErrors.UAgri__ComplianceDenied();
    }

    function _requireCustodyFreshIfEnabled() internal view {
        if (!enforceCustodyFreshOnRedeem) return;

        address custody = IAgriModulesV1(shareToken).custodyModule();
        if (custody == address(0)) revert FundingManager__InvalidConfig();

        UAgriTypes.ViewGasLimits memory g = IAgriModulesV1(shareToken).viewGasLimits();
        (bool ok, bool fresh) = SafeStaticCall.tryStaticCallBool(
            custody,
            uint256(g.custodyGas),
            abi.encodeWithSelector(IAgriCustodyV1.isCustodyFresh.selector, campaignId),
            0
        );
        if (!ok) revert UAgriErrors.UAgri__FailClosed();
        if (!fresh) revert UAgriErrors.UAgri__CustodyStale();
    }

    // ------------------------------ Cap logic ---------------------------------

    function _checkCap(uint256 netAssets) internal view {
        UAgriTypes.Campaign memory c = registry.getCampaign(campaignId);
        uint256 cap = c.fundingCap;
        if (cap == 0) return; // unlimited
        uint256 newTotal = totalRaisedNet + netAssets;
        if (newTotal > cap) revert FundingManager__CapExceeded(cap, newTotal);
    }

    // ------------------------------ Safe module calls -------------------------

    function _safeCampaignFlags() internal view returns (bool ok, uint256 flags) {
        address disaster = IAgriModulesV1(shareToken).disasterModule();
        if (disaster == address(0)) return (false, 0);

        UAgriTypes.ViewGasLimits memory g = IAgriModulesV1(shareToken).viewGasLimits();
        (ok, flags) = SafeStaticCall.tryStaticCallUint256(
            disaster,
            uint256(g.disasterGas),
            abi.encodeWithSelector(IAgriDisasterV1.campaignFlags.selector, campaignId),
            0
        );
    }

    function _safeIsRestrictedOrFailClosed() internal view returns (bool) {
        address disaster = IAgriModulesV1(shareToken).disasterModule();
        if (disaster == address(0)) return true;

        UAgriTypes.ViewGasLimits memory g = IAgriModulesV1(shareToken).viewGasLimits();
        (bool ok, bool restricted) = SafeStaticCall.tryStaticCallBool(
            disaster,
            uint256(g.disasterGas),
            abi.encodeWithSelector(IAgriDisasterV1.isRestricted.selector, campaignId),
            0
        );
        return !ok || restricted;
    }

    function _safeIsHardFrozenOrFailClosed() internal view returns (bool) {
        address disaster = IAgriModulesV1(shareToken).disasterModule();
        if (disaster == address(0)) return true;

        UAgriTypes.ViewGasLimits memory g = IAgriModulesV1(shareToken).viewGasLimits();
        (bool ok, bool frozen) = SafeStaticCall.tryStaticCallBool(
            disaster,
            uint256(g.disasterGas),
            abi.encodeWithSelector(IAgriDisasterV1.isHardFrozen.selector, campaignId),
            0
        );
        return !ok || frozen;
    }

    function _safeComplianceCanTransact(address account) internal view returns (bool) {
        address compliance = IAgriModulesV1(shareToken).complianceModule();
        if (compliance == address(0)) return false;

        UAgriTypes.ViewGasLimits memory g = IAgriModulesV1(shareToken).viewGasLimits();
        (bool ok, bool allowed) = SafeStaticCall.tryStaticCallBool(
            compliance,
            uint256(g.complianceGas),
            abi.encodeWithSelector(IAgriComplianceV1.canTransact.selector, account),
            0
        );
        return ok && allowed;
    }

    // ------------------------------ Conversions -------------------------------

    function _assetsToShares(uint256 assets) internal view returns (uint256) {
        // shares = assets * shareUnit / assetUnit
        return _mulDiv(assets, _shareUnit, _assetUnit);
    }

    function _sharesToAssets(uint256 shares) internal view returns (uint256) {
        // assets = shares * assetUnit / shareUnit
        return _mulDiv(shares, _assetUnit, _shareUnit);
    }

    function _assetsToSharesRoundUp(uint256 assets) internal view returns (uint256) {
        return _mulDivRoundingUp(assets, _shareUnit, _assetUnit);
    }

    function _sharesToAssetsRoundUp(uint256 shares) internal view returns (uint256) {
        return _mulDivRoundingUp(shares, _assetUnit, _shareUnit);
    }

    function _fee(uint256 amount, uint16 bps) internal pure returns (uint256) {
        if (bps == 0 || amount == 0) return 0;
        return (amount * uint256(bps)) / 10_000;
    }

    // ------------------------------ RBAC helpers ------------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller)
        ) revert UAgriErrors.UAgri__Unauthorized();
    }

    function _requireOperatorOrTreasury() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.FARM_OPERATOR_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.TREASURY_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) revert UAgriErrors.UAgri__Unauthorized();
    }

    function _requireOnRampDepositOperator() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.ONRAMP_OPERATOR_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.TREASURY_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) revert UAgriErrors.UAgri__Unauthorized();
    }

    // ------------------------------ Utils ------------------------------------

    function _refreshSettlementAssetAndUnits() internal {
        address treasury_ = IAgriModulesV1(shareToken).treasury();
        if (treasury_ == address(0)) revert FundingManager__InvalidTreasury();

        address asset_ = IAgriTreasuryV1(treasury_).settlementAsset();
        if (asset_ == address(0)) revert FundingManager__InvalidSettlementAsset();

        settlementAsset = asset_;

        uint8 aDec = _detectDecimals(asset_);
        uint8 sDec = _detectShareDecimals(shareToken);

        _assetUnit = _pow10(aDec);
        _shareUnit = _pow10(sDec);

        emit SettlementAssetRefreshed(asset_, aDec, sDec);
    }

    function _detectShareDecimals(address token) internal view returns (uint8) {
        // AgriShareToken exposes decimals() reliably, but we fall back to 18.
        try IAgriShareOps(token).decimals() returns (uint8 d) {
            if (d > 18) return 18;
            return d;
        } catch {
            return 18;
        }
    }

    function _detectDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(IERC20Decimals.decimals.selector));
        if (!ok || ret.length < 32) return 18;
        uint256 v = abi.decode(ret, (uint256));
        if (v > 18) return 18;
        return uint8(v);
    }

    function _pow10(uint8 decimals) internal pure returns (uint256) {
        uint256 x = 1;
        for (uint256 i = 0; i < uint256(decimals); i++) {
            x *= 10;
        }
        return x;
    }

    /// @dev Full precision mulDiv (floor), adapted from OpenZeppelin Math.mulDiv.
    function _mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 mm = mulmod(x, y, type(uint256).max);
            uint256 prod0 = x * y;
            uint256 prod1 = mm - prod0 - (mm < prod0 ? 1 : 0);

            if (prod1 == 0) {
                return prod0 / denominator;
            }

            require(denominator > prod1);

            uint256 remainder = mulmod(x, y, denominator);
            prod1 = prod1 - (remainder > prod0 ? 1 : 0);
            prod0 = prod0 - remainder;

            uint256 twos = denominator & (~denominator + 1);
            denominator /= twos;
            prod0 /= twos;
            twos = (type(uint256).max / twos) + 1;

            prod0 |= prod1 * twos;

            uint256 inv = 3 * denominator ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;

            result = prod0 * inv;
        }
    }

    function _mulDivRoundingUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        uint256 r = _mulDiv(x, y, denominator);
        unchecked {
            if (mulmod(x, y, denominator) > 0) r += 1;
        }
        return r;
    }
}
