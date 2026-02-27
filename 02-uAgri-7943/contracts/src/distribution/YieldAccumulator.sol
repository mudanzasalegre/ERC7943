// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriDistributionV1} from "../interfaces/v1/IAgriDistributionV1.sol";
import {IAgriModulesV1} from "../interfaces/v1/IAgriModulesV1.sol";
import {IAgriComplianceV1} from "../interfaces/v1/IAgriComplianceV1.sol";
import {IAgriDisasterV1} from "../interfaces/v1/IAgriDisasterV1.sol";
import {IAgriTreasuryV1} from "../interfaces/v1/IAgriTreasuryV1.sol";

import {UAgriTypes} from "../interfaces/constants/UAgriTypes.sol";
import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriFlags} from "../interfaces/constants/UAgriFlags.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

import {RoleManager} from "../access/RoleManager.sol";
import {ReentrancyGuard} from "../_shared/ReentrancyGuard.sol";
import {SafeERC20} from "../_shared/SafeERC20.sol";
import {SafeStaticCall} from "../_shared/SafeStaticCall.sol";
import {EIP712} from "../_shared/EIP712.sol";
import {ECDSA} from "../_shared/ECDSA.sol";

/// @dev Minimal ERC-20 views for the share token.
interface IShareTokenViews {
    function roleManager() external view returns (address);
    function campaignId() external view returns (bytes32);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}

/// @title YieldAccumulator
/// @notice V1 reward distribution module for a single campaign share token.
/// @dev “Magnified reward per share” accumulator (dividend-per-share).
///      - notifyReward(): pulls rewardToken from campaign treasury and increases accumulator.
///      - claim()/claimFor(): pays rewardToken to account based on current balances + corrections.
///      Optional hooks (onMint/onBurn/onTransfer) enable snapshot-like attribution.
///      If hooks are NOT used, rewards follow shares (current holder can claim).
contract YieldAccumulator is IAgriDistributionV1, ReentrancyGuard, EIP712 {
    using ECDSA for bytes32;

    // -------------------------------- Events --------------------------------
    event NotifierUpdated(address indexed notifier, bool allowed);
    event ComplianceOnClaimToggled(bool enabled);
    event HooksRequiredToggled(bool enabled);

    // -------------------------------- Errors --------------------------------
    error YieldAccumulator__AlreadyInitialized();
    error YieldAccumulator__InvalidRoleManager();
    error YieldAccumulator__InvalidShareToken();
    error YieldAccumulator__InvalidRewardToken();
    error YieldAccumulator__RoleManagerMismatch();
    error YieldAccumulator__InvalidCampaignId();
    error YieldAccumulator__UnauthorizedNotifier();
    error YieldAccumulator__HooksRequired();
    error YieldAccumulator__InvalidLiquidationId();
    error YieldAccumulator__InvalidReportHash();
    error YieldAccumulator__InvalidRef();
    error YieldAccumulator__InvalidReceiptHash();
    error YieldAccumulator__PayoutNotFound();
    error YieldAccumulator__PayoutAlreadyConfirmed();

    // ------------------------------- Constants -------------------------------
    uint256 internal constant MAGNITUDE = 1e27;
    bytes32 internal constant CLAIM_TO_WITH_SIG_TYPEHASH =
        keccak256(
            "ClaimToWithSig(address account,address to,uint256 maxAmount,uint64 deadline,bytes32 ref,bytes32 payoutRailHash)"
        );
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    // -------------------------------- Storage --------------------------------
    RoleManager public roleManager;
    bytes32 public campaignId;

    /// @notice Share token for this campaign.
    address public shareToken;

    /// @notice Reward token distributed by this module.
    address public rewardToken;

    /// @notice Accumulator (scaled by MAGNITUDE).
    uint256 public magnifiedRewardPerShare;

    /// @notice Corrections applied on mint/burn/transfer (snapshot attribution).
    mapping(address => int256) public magnifiedCorrections;

    /// @notice Amount already withdrawn by account.
    mapping(address => uint256) public withdrawnRewards;

    struct PayoutInfo {
        address account;
        address to;
        uint256 amount;
        bytes32 payoutRailHash;
        bytes32 receiptHash;
        uint256 liquidationIdAtRequest;
    }

    mapping(bytes32 => bool) public usedPayoutRef;
    mapping(bytes32 => PayoutInfo) public payoutByRef;

    /// @notice Rewards carried when supply is zero.
    uint256 public undistributed;

    /// @notice Last settlement liquidation identifier for this campaign.
    uint256 public lastLiquidationId;

    /// @notice Accounting per liquidation identifier.
    mapping(uint256 => uint256) public rewardByLiquidationId;
    mapping(uint256 => bytes32) public reportHashByLiquidationId;

    /// @notice Legacy notifier allowlist metadata (ACL is role-based via REWARD_NOTIFIER_ROLE/admin/gov).
    mapping(address => bool) public isNotifier;

    /// @notice Optional: enforce compliance.canTransact(to) on claim() (fail-closed).
    bool public enforceComplianceOnClaim;

    /// @notice Optional: require that token hooks have been observed before allowing notifyReward.
    bool public requireHooks;

    /// @dev Set true once any hook is called (guardrail for requireHooks).
    bool public hooksSeen;

    bool private _initialized;

    // -------------------------------- Modifiers ------------------------------
    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    modifier onlyNotifier() {
        _requireNotifier();
        _;
    }

    modifier onlyShareToken() {
        if (msg.sender != shareToken) revert UAgriErrors.UAgri__Unauthorized();
        _;
    }

    // ------------------------------ Init / Config ----------------------------
    constructor(
        address roleManager_,
        address shareToken_,
        address rewardToken_,
        bool enforceComplianceOnClaim_
    ) EIP712("uAgri Payout", "1") {
        _init(
            roleManager_,
            shareToken_,
            rewardToken_,
            enforceComplianceOnClaim_
        );
    }

    function initialize(
        address roleManager_,
        address shareToken_,
        address rewardToken_,
        bool enforceComplianceOnClaim_
    ) external {
        _init(
            roleManager_,
            shareToken_,
            rewardToken_,
            enforceComplianceOnClaim_
        );
    }

    function _init(
        address roleManager_,
        address shareToken_,
        address rewardToken_,
        bool enforceComplianceOnClaim_
    ) internal {
        if (_initialized) revert YieldAccumulator__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0))
            revert YieldAccumulator__InvalidRoleManager();
        if (shareToken_ == address(0))
            revert YieldAccumulator__InvalidShareToken();
        if (rewardToken_ == address(0))
            revert YieldAccumulator__InvalidRewardToken();

        // Validate share token roleManager/campaignId.
        address rmOnToken = IShareTokenViews(shareToken_).roleManager();
        if (rmOnToken != roleManager_)
            revert YieldAccumulator__RoleManagerMismatch();

        bytes32 cid = IShareTokenViews(shareToken_).campaignId();
        if (cid == bytes32(0)) revert YieldAccumulator__InvalidCampaignId();

        roleManager = RoleManager(roleManager_);
        shareToken = shareToken_;
        rewardToken = rewardToken_;
        campaignId = cid;

        enforceComplianceOnClaim = enforceComplianceOnClaim_;
        emit ComplianceOnClaimToggled(enforceComplianceOnClaim_);
    }

    // --------------------------- IAgriDistributionV1 --------------------------
    function pending(address account) external view override returns (uint256) {
        return _withdrawableOf(account);
    }

    function domainSeparator() external view returns (bytes32) {
        return domainSeparatorV4();
    }

    function hashPayoutClaimStruct(
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CLAIM_TO_WITH_SIG_TYPEHASH,
                    account,
                    to,
                    maxAmount,
                    deadline,
                    ref,
                    payoutRailHash
                )
            );
    }

    function hashPayoutClaim(
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash
    ) public view returns (bytes32) {
        return
            _hashTypedDataV4(
                hashPayoutClaimStruct(
                    account,
                    to,
                    maxAmount,
                    deadline,
                    ref,
                    payoutRailHash
                )
            );
    }

    /// @notice Returns the next valid liquidation identifier (strictly incremental).
    function nextLiquidationId() external view returns (uint256) {
        return lastLiquidationId + 1;
    }

    /// @notice Claim rewards to msg.sender.
    function claim() external override nonReentrant returns (uint256 paid) {
        _requireClaimsAllowed();
        paid = _claimTo(msg.sender);
    }

    /// @notice Claim rewards for `account`, paying to `account`.
    /// @dev Anyone can trigger; funds go to the account (safe “helpful claim”).
    function claimFor(
        address account
    ) external override nonReentrant returns (uint256 paid) {
        if (account == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        _requireClaimsAllowed();
        paid = _claimTo(account);
    }

    function claimToWithSig(
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash,
        bytes calldata signature
    ) external nonReentrant returns (uint256 paid) {
        _requireClaimsAllowed();
        _requirePayoutOperator();

        if (account == address(0) || to == address(0))
            revert UAgriErrors.UAgri__InvalidAddress();
        if (maxAmount == 0) revert UAgriErrors.UAgri__InvalidAmount();
        if (ref == bytes32(0)) revert YieldAccumulator__InvalidRef();
        if (usedPayoutRef[ref]) revert UAgriErrors.UAgri__Replay();
        if (deadline != 0 && block.timestamp > deadline) {
            revert UAgriErrors.UAgri__DeadlineExpired();
        }

        _requireValidPayoutSignature(
            account,
            to,
            maxAmount,
            deadline,
            ref,
            payoutRailHash,
            signature
        );

        if (enforceComplianceOnClaim) {
            _requireComplianceCanTransact(account);
        }

        paid = _min(_withdrawableOf(account), maxAmount);
        paid = _min(paid, SafeERC20.balanceOf(rewardToken, address(this)));

        usedPayoutRef[ref] = true;
        withdrawnRewards[account] += paid;

        if (paid != 0) {
            SafeERC20.safeTransfer(rewardToken, to, paid);
        }

        uint256 liquidationIdAtRequest = lastLiquidationId;
        payoutByRef[ref] = PayoutInfo({
            account: account,
            to: to,
            amount: paid,
            payoutRailHash: payoutRailHash,
            receiptHash: bytes32(0),
            liquidationIdAtRequest: liquidationIdAtRequest
        });

        emit PayoutRequested(
            ref,
            account,
            to,
            paid,
            payoutRailHash,
            liquidationIdAtRequest
        );
    }

    function confirmPayout(bytes32 ref, bytes32 receiptHash) external nonReentrant {
        _requirePayoutConfirmer();
        if (ref == bytes32(0)) revert YieldAccumulator__InvalidRef();
        if (receiptHash == bytes32(0))
            revert YieldAccumulator__InvalidReceiptHash();

        PayoutInfo storage info = payoutByRef[ref];
        if (info.account == address(0))
            revert YieldAccumulator__PayoutNotFound();
        if (info.receiptHash != bytes32(0)) {
            revert YieldAccumulator__PayoutAlreadyConfirmed();
        }

        info.receiptHash = receiptHash;
        emit PayoutConfirmed(ref, receiptHash);
    }

    /// @notice Notify rewards: pulls settlement proceeds from campaign treasury and updates per-share accumulator.
    /// @param amount Amount to request from treasury (credits actual received).
    /// @param liquidationId Strictly sequential liquidation identifier (1,2,3...).
    /// @param reportHash Hash pointer for offchain liquidation report.
    function notifyReward(
        uint256 amount,
        uint64 liquidationId,
        bytes32 reportHash
    ) external override nonReentrant onlyNotifier {
        if (amount == 0) revert UAgriErrors.UAgri__InvalidAmount();
        if (reportHash == bytes32(0)) revert YieldAccumulator__InvalidReportHash();

        if (requireHooks && !hooksSeen)
            revert YieldAccumulator__HooksRequired();

        uint256 nextId = lastLiquidationId + 1;
        uint256 liquidationIdU256 = uint256(liquidationId);
        if (liquidationIdU256 != nextId) revert YieldAccumulator__InvalidLiquidationId();

        address rt = rewardToken;
        address treasury = IAgriModulesV1(shareToken).treasury();
        if (treasury == address(0)) revert UAgriErrors.UAgri__FailClosed();

        // Fee-on-transfer support: credit actual received from treasury payout.
        uint256 beforeBal = SafeERC20.balanceOf(rt, address(this));
        IAgriTreasuryV1(treasury).pay(address(this), amount, _rewardMemo(liquidationIdU256, reportHash));
        uint256 afterBal = SafeERC20.balanceOf(rt, address(this));
        uint256 received = afterBal - beforeBal;

        uint256 distributable = received + undistributed;

        lastLiquidationId = liquidationIdU256;
        rewardByLiquidationId[liquidationIdU256] = received;
        reportHashByLiquidationId[liquidationIdU256] = reportHash;

        uint256 supply = IShareTokenViews(shareToken).totalSupply();
        if (supply == 0) {
            undistributed = distributable;
            emit RewardNotified(distributable, liquidationId, reportHash);
            return;
        }

        undistributed = 0;
        magnifiedRewardPerShare += (distributable * MAGNITUDE) / supply;

        emit RewardNotified(distributable, liquidationId, reportHash);
    }

    // ------------------------------ Optional Token Hooks ----------------------
    // If AgriShareToken calls these, rewards are attributed snapshot-style.
    // Otherwise rewards follow shares (current holder can claim).

    function onMint(address to, uint256 amount) external onlyShareToken {
        if (!hooksSeen) hooksSeen = true;
        if (to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (amount == 0) return;

        // Newly minted shares should not receive past rewards.
        magnifiedCorrections[to] -= int256(magnifiedRewardPerShare * amount);
    }

    function onBurn(address from, uint256 amount) external onlyShareToken {
        if (!hooksSeen) hooksSeen = true;
        if (from == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (amount == 0) return;

        // Burned shares keep their past rewards with the burner.
        magnifiedCorrections[from] += int256(magnifiedRewardPerShare * amount);
    }

    function onTransfer(
        address from,
        address to,
        uint256 amount
    ) external onlyShareToken {
        if (!hooksSeen) hooksSeen = true;
        if (from == address(0) || to == address(0))
            revert UAgriErrors.UAgri__InvalidAddress();
        if (amount == 0) return;

        int256 mag = int256(magnifiedRewardPerShare * amount);
        magnifiedCorrections[from] += mag;
        magnifiedCorrections[to] -= mag;
    }

    // ----------------------------- Governance API ----------------------------
    function setNotifier(
        address notifier,
        bool allowed
    ) external onlyGovernance {
        if (notifier == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        isNotifier[notifier] = allowed;
        emit NotifierUpdated(notifier, allowed);
    }

    function setEnforceComplianceOnClaim(bool enabled) external onlyGovernance {
        enforceComplianceOnClaim = enabled;
        emit ComplianceOnClaimToggled(enabled);
    }

    /// @dev ✅ Guardrail: no dejes activar modo estricto si todavía no has visto hooks reales.
    function setRequireHooks(bool enabled) external onlyGovernance {
        if (enabled && !hooksSeen) revert YieldAccumulator__HooksRequired();
        requireHooks = enabled;
        emit HooksRequiredToggled(enabled);
    }

    function recoverERC20(
        address token,
        address to,
        uint256 amount
    ) external nonReentrant onlyGovernance {
        if (token == address(0) || to == address(0))
            revert UAgriErrors.UAgri__InvalidAddress();
        if (amount == 0) revert UAgriErrors.UAgri__InvalidAmount();
        SafeERC20.safeTransfer(token, to, amount);
    }

    // ------------------------------ Internal Claim ----------------------------
    function _claimTo(address account) internal returns (uint256 paid) {
        if (enforceComplianceOnClaim) {
            _requireComplianceCanTransact(account);
        }

        uint256 amount = _withdrawableOf(account);
        if (amount == 0) return 0;

        withdrawnRewards[account] += amount;

        // Safety cap (rounding/edge tokens): do not exceed balance.
        uint256 bal = SafeERC20.balanceOf(rewardToken, address(this));
        if (amount > bal) amount = bal;

        if (amount != 0) {
            SafeERC20.safeTransfer(rewardToken, account, amount);
        }

        emit Claimed(account, amount);
        return amount;
    }

    // ------------------------------ Internal Math ----------------------------
    function _withdrawableOf(address account) internal view returns (uint256) {
        uint256 bal = IShareTokenViews(shareToken).balanceOf(account);

        // accum = (magnifiedRewardPerShare * bal + correction) / MAGNITUDE
        int256 corrected = int256(magnifiedRewardPerShare * bal) +
            magnifiedCorrections[account];
        if (corrected <= 0) return 0;

        uint256 accum = uint256(corrected) / MAGNITUDE;
        uint256 withdrawn = withdrawnRewards[account];
        if (accum <= withdrawn) return 0;

        return accum - withdrawn;
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

    function _requireNotifier() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;
        if (
            rm.hasRole(UAgriRoles.REWARD_NOTIFIER_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) return;

        revert YieldAccumulator__UnauthorizedNotifier();
    }

    function _requirePayoutOperator() internal view {
        if (!roleManager.hasRole(UAgriRoles.PAYOUT_OPERATOR_ROLE, msg.sender)) {
            revert UAgriErrors.UAgri__Unauthorized();
        }
    }

    function _requirePayoutConfirmer() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;
        if (
            rm.hasRole(UAgriRoles.PAYOUT_OPERATOR_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) return;

        revert UAgriErrors.UAgri__Unauthorized();
    }

    function _requireClaimsAllowed() internal view {
        address token = shareToken;

        address disaster = IAgriModulesV1(token).disasterModule();
        if (disaster == address(0)) revert UAgriErrors.UAgri__FailClosed();

        UAgriTypes.ViewGasLimits memory g = IAgriModulesV1(token).viewGasLimits();
        uint256 gasCap = uint256(g.disasterGas);

        (bool okFlags, uint256 flags) = SafeStaticCall.tryStaticCallUint256(
            disaster,
            gasCap,
            abi.encodeWithSelector(IAgriDisasterV1.campaignFlags.selector, campaignId),
            0
        );
        if (!okFlags) revert UAgriErrors.UAgri__FailClosed();
        if ((flags & UAgriFlags.PAUSE_CLAIMS) != 0) revert UAgriErrors.UAgri__Paused();

        (bool okRestricted, bool restricted) = SafeStaticCall.tryStaticCallBool(
            disaster,
            gasCap,
            abi.encodeWithSelector(IAgriDisasterV1.isRestricted.selector, campaignId),
            0
        );
        if (!okRestricted) revert UAgriErrors.UAgri__FailClosed();
        if (restricted) revert UAgriErrors.UAgri__Restricted();

        (bool okFrozen, bool hardFrozen) = SafeStaticCall.tryStaticCallBool(
            disaster,
            gasCap,
            abi.encodeWithSelector(IAgriDisasterV1.isHardFrozen.selector, campaignId),
            0
        );
        if (!okFrozen) revert UAgriErrors.UAgri__FailClosed();
        if (hardFrozen) revert UAgriErrors.UAgri__HardFrozen();
    }

    // -------------------------- Optional Compliance --------------------------
    function _requireComplianceCanTransact(address account) internal view {
        address token = shareToken;

        address compliance = IAgriModulesV1(token).complianceModule();
        if (compliance == address(0)) revert UAgriErrors.UAgri__FailClosed();

        UAgriTypes.ViewGasLimits memory g = IAgriModulesV1(token)
            .viewGasLimits();
        (bool ok, bool allowed) = SafeStaticCall.tryStaticCallBool(
            compliance,
            uint256(g.complianceGas),
            abi.encodeWithSelector(
                IAgriComplianceV1.canTransact.selector,
                account
            ),
            0
        );

        if (!ok) revert UAgriErrors.UAgri__FailClosed();
        if (!allowed) revert UAgriErrors.UAgri__ComplianceDenied();
    }

    function _requireValidPayoutSignature(
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash,
        bytes calldata signature
    ) internal view {
        bytes32 digest = hashPayoutClaim(
            account,
            to,
            maxAmount,
            deadline,
            ref,
            payoutRailHash
        );

        if (account.code.length != 0) {
            bytes4 magic = IERC1271(account).isValidSignature(digest, signature);
            if (magic != EIP1271_MAGIC_VALUE)
                revert UAgriErrors.UAgri__InvalidSignature();
            return;
        }

        address signer = digest.recover(signature);
        if (signer != account) revert UAgriErrors.UAgri__InvalidSignature();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _rewardMemo(uint256 liquidationId, bytes32 reportHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("UAGRI_REWARD", campaignId, liquidationId, reportHash));
    }
}
