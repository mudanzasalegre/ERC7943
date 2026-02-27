// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAgriInsuranceV1} from "../interfaces/v1/IAgriInsuranceV1.sol";
import {IAgriDisasterAdminV1} from "../interfaces/v1/IAgriDisasterAdminV1.sol";

import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

import {RoleManager} from "../access/RoleManager.sol";

import {SafeERC20} from "../_shared/SafeERC20.sol";
import {ReentrancyGuard} from "../_shared/ReentrancyGuard.sol";
import {SafeStaticCall} from "../_shared/SafeStaticCall.sol";

/// @dev Minimal interface to SnapshotModule (src/distribution/SnapshotModule.sol) in your repo.
interface ISnapshotModuleLike {
    function campaignId() external view returns (bytes32);

    function balanceOfAtEpoch(address account, uint64 epoch) external view returns (uint256);
    function totalSupplyAtEpoch(uint64 epoch) external view returns (uint256);
}

/// @title InsurancePool
/// @notice “Official” insurance/compensation pool. Pro-rata payout by Snapshot epoch.
/// @dev RECETA MAESTRA (Standard-Grade) alignment:
///  - Compensation is **dual-control gated** by requiring a confirmed Disaster event:
///      * notifyCompensation() only executable when DisasterModule.getDisaster(campaignId).confirmed == true
///      * notifyCompensation() is governance-only (timelock/multisig profile)
///  - Payout rule (epoch-based):
///      payout = round.amount * balanceOfAtEpoch(account, epoch) / round.totalSupply
///    where round.totalSupply is cached at notify-time to lock the math.
///  - Solvency:
///      totalRemaining = sum(round.remaining). Governance can only withdraw excess = balance - totalRemaining.
///  - No double counting per report/evidence:
///      reasonHash must be non-zero and unique per notified round (global uniqueness in this pool).
///  - NOTE:
///      IAgriInsuranceV1 event CompensationClaimed has ONLY (account, amount).
///      If you want epoch in logs, we emit an extra event with different name.
contract InsurancePool is IAgriInsuranceV1, ReentrancyGuard {
    // -------------------------------- Errors --------------------------------

    error InsurancePool__AlreadyInitialized();
    error InsurancePool__InvalidRoleManager();
    error InsurancePool__InvalidCampaignId();
    error InsurancePool__InvalidPayoutToken();
    error InsurancePool__InvalidSnapshotModule();
    error InsurancePool__InvalidDisasterModule();

    error InsurancePool__AmountZero();
    error InsurancePool__ReasonHashRequired();
    error InsurancePool__ReasonAlreadyUsed(bytes32 reasonHash);

    error InsurancePool__EpochNotIncreasing(uint64 provided, uint64 current);
    error InsurancePool__SnapshotTotalSupplyZero(uint64 epoch);
    error InsurancePool__Underfunded(uint256 required, uint256 balance);
    error InsurancePool__Paused();

    error InsurancePool__DisasterNotConfirmed(bytes32 campaignId);

    // -------------------------------- Storage --------------------------------

    RoleManager public roleManager;
    bool private _initialized;

    /// @notice Campaign identifier (same bytes32 as the rest of the kit).
    bytes32 public campaignId;

    /// @notice ERC20 token used for payouts (e.g., stablecoin).
    address public payoutToken;

    /// @notice SnapshotModule used to read balances/totalSupply at epoch.
    address public snapshotModule;

    /// @notice DisasterModule (must implement IAgriDisasterAdminV1) used for dual-control gating.
    address public disasterModule;

    /// @notice Optional pause for claims.
    bool public paused;

    struct Round {
        uint256 amount;       // total compensation allocated for this epoch
        uint256 remaining;    // unpaid remainder (reserved)
        uint256 totalSupply;  // totalSupplyAtEpoch(epoch) cached
        bytes32 reasonHash;   // evidence pack hash / report hash
        bool exists;
    }

    /// @notice Latest compensation epoch ever notified.
    uint64 public latestEpoch;

    /// @notice Reserved funds = sum of remaining across all rounds.
    uint256 public totalRemaining;

    mapping(uint64 => Round) private _rounds;

    /// @notice Last epoch processed by account in claimCompensation().
    mapping(address => uint64) public lastClaimedEpoch;

    /// @dev Prevent double-counting evidence packs.
    mapping(bytes32 => bool) public reasonHashUsed;

    // -------------------------------- Extra Events ---------------------------

    event Initialized(
        address indexed roleManager,
        bytes32 indexed campaignId,
        address indexed payoutToken,
        address snapshotModule,
        address disasterModule
    );
    event SnapshotModuleSet(address indexed oldModule, address indexed newModule);
    event DisasterModuleSet(address indexed oldModule, address indexed newModule);
    event PayoutTokenSet(address indexed oldToken, address indexed newToken);
    event PausedSet(bool paused);
    event Funded(address indexed from, uint256 amount);
    event ExcessWithdrawn(address indexed to, uint256 amount, address indexed caller);
    event DustSwept(uint64 indexed epoch, address indexed to, uint256 amount, address indexed caller);

    /// @dev Extra detail event (epoch) without breaking the official interface event.
    event CompensationClaimedForEpoch(address indexed account, uint256 amount, uint64 indexed epoch);

    // ------------------------------ Snapshot SafeCall ------------------------

    uint256 internal constant SNAPSHOT_GAS_STIPEND = 40_000;
    uint256 internal constant SNAPSHOT_MAX_RET = 32;

    // ------------------------------ Init ------------------------------------

    constructor(
        address roleManager_,
        bytes32 campaignId_,
        address payoutToken_,
        address snapshotModule_,
        address disasterModule_
    ) {
        _init(roleManager_, campaignId_, payoutToken_, snapshotModule_, disasterModule_);
    }

    function initialize(
        address roleManager_,
        bytes32 campaignId_,
        address payoutToken_,
        address snapshotModule_,
        address disasterModule_
    ) external {
        _init(roleManager_, campaignId_, payoutToken_, snapshotModule_, disasterModule_);
    }

    function _init(
        address roleManager_,
        bytes32 campaignId_,
        address payoutToken_,
        address snapshotModule_,
        address disasterModule_
    ) internal {
        if (_initialized) revert InsurancePool__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert InsurancePool__InvalidRoleManager();
        roleManager = RoleManager(roleManager_);

        if (campaignId_ == bytes32(0)) revert InsurancePool__InvalidCampaignId();
        campaignId = campaignId_;

        _setPayoutTokenInternal(payoutToken_);
        _setSnapshotModuleInternal(snapshotModule_, campaignId_);
        _setDisasterModuleInternal(disasterModule_);

        emit Initialized(roleManager_, campaignId_, payoutToken_, snapshotModule_, disasterModule_);
    }

    // -------------------------- IAgriInsuranceV1 ----------------------------

    /// @inheritdoc IAgriInsuranceV1
    function notifyCompensation(uint256 amount, uint64 epoch, bytes32 reasonHash) external {
        // Standard-grade: compensation is a critical action => governance-only.
        _requireGovernance();

        // Dual-control gate: only executable if the campaign disaster is confirmed.
        _requireDisasterConfirmed();

        if (amount == 0) revert InsurancePool__AmountZero();
        if (reasonHash == bytes32(0)) revert InsurancePool__ReasonHashRequired();
        if (reasonHashUsed[reasonHash]) revert InsurancePool__ReasonAlreadyUsed(reasonHash);

        // Epoch must increase (monotonic rounds).
        if (epoch <= latestEpoch) revert InsurancePool__EpochNotIncreasing(epoch, latestEpoch);

        address sm = snapshotModule;
        if (sm == address(0) || sm.code.length == 0) revert InsurancePool__InvalidSnapshotModule();

        // Cache total supply at epoch (safe call).
        (bool okTs, uint256 ts) = _safeTotalSupplyAtEpoch(sm, epoch);
        if (!okTs || ts == 0) revert InsurancePool__SnapshotTotalSupplyZero(epoch);

        // Book new round.
        Round storage r = _rounds[epoch];
        r.amount = amount;
        r.remaining = amount;
        r.totalSupply = ts;
        r.reasonHash = reasonHash;
        r.exists = true;

        latestEpoch = epoch;

        // Reserve (solvency).
        totalRemaining += amount;

        // Mark evidence pack as used (no double counting).
        reasonHashUsed[reasonHash] = true;

        // Ensure we are funded enough to cover all outstanding rounds.
        uint256 bal = SafeERC20.balanceOf(payoutToken, address(this));
        if (bal < totalRemaining) revert InsurancePool__Underfunded(totalRemaining, bal);

        emit CompensationNotified(amount, epoch, reasonHash);
    }

    /// @inheritdoc IAgriInsuranceV1
    function claimCompensation() external nonReentrant returns (uint256 paid) {
        return _claimUpTo(latestEpoch);
    }

    // ------------------------------ Optional UX -----------------------------

    /// @notice Claim compensation only up to `maxEpoch` (gas-control helper).
    function claimCompensationUpTo(uint64 maxEpoch) external nonReentrant returns (uint256 paid) {
        return _claimUpTo(maxEpoch);
    }

    function _claimUpTo(uint64 maxEpoch) internal returns (uint256 paid) {
        if (paused) revert InsurancePool__Paused();

        uint64 end = latestEpoch;
        if (end == 0) return 0;

        if (maxEpoch < end) end = maxEpoch;
        if (end == 0) return 0;

        uint64 start = lastClaimedEpoch[msg.sender] + 1;
        if (start > end) return 0;

        address sm = snapshotModule;
        if (sm == address(0) || sm.code.length == 0) {
            // No avanzamos lastClaimedEpoch para no “quemar” epochs si hay mala config temporal.
            return 0;
        }

        address token = payoutToken;

        uint64 processedUntil = start - 1;
        uint64 e = start;

        while (true) {
            Round storage r = _rounds[e];
            if (r.exists && r.amount != 0 && r.remaining != 0) {
                (bool okBal, uint256 balAt) = _safeBalanceOfAtEpoch(sm, msg.sender, e);

                // Si el snapshot falla (módulo caído/malicioso), paramos sin avanzar epochs.
                if (!okBal) break;

                if (balAt != 0) {
                    // pro-rata: amount * balance / totalSupply
                    uint256 claimable = (r.amount * balAt) / r.totalSupply;
                    if (claimable != 0) {
                        if (claimable > r.remaining) claimable = r.remaining;

                        r.remaining -= claimable;
                        totalRemaining -= claimable;

                        SafeERC20.safeTransfer(token, msg.sender, claimable);

                        paid += claimable;

                        // ✅ evento oficial (2 args)
                        emit CompensationClaimed(msg.sender, claimable);
                        // ✅ evento extra con epoch
                        emit CompensationClaimedForEpoch(msg.sender, claimable, e);
                    }
                }
            }

            processedUntil = e;

            if (e == end) break;
            unchecked {
                e++;
            }
        }

        // Solo avanzamos hasta donde hemos podido procesar sin fallo del snapshot.
        if (processedUntil >= start) {
            lastClaimedEpoch[msg.sender] = processedUntil;
        }

        return paid;
    }

    // ------------------------------ Views -----------------------------------

    function lastCompensation() external view returns (uint256 amount, uint64 epoch, bytes32 reasonHash) {
        epoch = latestEpoch;
        if (epoch == 0) return (0, 0, bytes32(0));
        Round storage r = _rounds[epoch];
        return (r.amount, epoch, r.reasonHash);
    }

    function roundOf(uint64 epoch) external view returns (Round memory) {
        return _rounds[epoch];
    }

    function previewClaim(address account)
        external
        view
        returns (uint256 claimableTotal, uint64 fromEpoch, uint64 toEpoch)
    {
        return _previewClaimUpTo(account, latestEpoch);
    }

    function previewClaimUpTo(address account, uint64 maxEpoch)
        external
        view
        returns (uint256 claimableTotal, uint64 fromEpoch, uint64 toEpoch)
    {
        return _previewClaimUpTo(account, maxEpoch);
    }

    function _previewClaimUpTo(address account, uint64 maxEpoch)
        internal
        view
        returns (uint256 claimableTotal, uint64 fromEpoch, uint64 toEpoch)
    {
        toEpoch = latestEpoch;
        if (toEpoch == 0) return (0, 0, 0);

        if (maxEpoch < toEpoch) toEpoch = maxEpoch;
        if (toEpoch == 0) return (0, 0, 0);

        fromEpoch = lastClaimedEpoch[account] + 1;
        if (fromEpoch > toEpoch) return (0, fromEpoch, toEpoch);

        address sm = snapshotModule;
        if (sm == address(0) || sm.code.length == 0) return (0, fromEpoch, toEpoch);

        uint64 e = fromEpoch;
        while (true) {
            Round storage r = _rounds[e];
            if (r.exists && r.amount != 0 && r.remaining != 0) {
                (bool okBal, uint256 balAt) = _safeBalanceOfAtEpoch(sm, account, e);
                if (okBal && balAt != 0) {
                    uint256 c = (r.amount * balAt) / r.totalSupply;
                    if (c > r.remaining) c = r.remaining;
                    claimableTotal += c;
                }
            }

            if (e == toEpoch) break;
            unchecked {
                e++;
            }
        }
    }

    function withdrawableExcess() public view returns (uint256) {
        uint256 bal = SafeERC20.balanceOf(payoutToken, address(this));
        if (bal <= totalRemaining) return 0;
        return bal - totalRemaining;
    }

    // ------------------------------ Funding ---------------------------------

    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) return;
        SafeERC20.safeTransferFrom(payoutToken, msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    // ------------------------------ Admin -----------------------------------

    function setPaused(bool paused_) external {
        _requireGuardianOrGovernance();
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @dev Snapshot module change is critical; governance-only.
    function setSnapshotModule(address newModule) external {
        _requireGovernance();
        _setSnapshotModuleInternal(newModule, campaignId);
    }

    /// @dev Disaster module change is critical; governance-only.
    function setDisasterModule(address newModule) external {
        _requireGovernance();
        _setDisasterModuleInternal(newModule);
    }

    /// @dev Only allow changing payout token when there are no pending reserves.
    function setPayoutToken(address newToken) external {
        _requireGovernance();
        if (totalRemaining != 0) {
            revert InsurancePool__Underfunded(totalRemaining, SafeERC20.balanceOf(payoutToken, address(this)));
        }
        _setPayoutTokenInternal(newToken);
    }

    /// @notice Withdraw funds that are NOT reserved for pending compensation rounds.
    /// @dev Critical action => governance-only (timelock/multisig).
    function withdrawExcess(address to, uint256 amount) external nonReentrant {
        _requireGovernance();
        if (to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();

        uint256 avail = withdrawableExcess();
        if (amount > avail) revert InsurancePool__Underfunded(amount, avail);

        SafeERC20.safeTransfer(payoutToken, to, amount);
        emit ExcessWithdrawn(to, amount, msg.sender);
    }

    /// @notice Sweep leftover dust (or unclaimed remainder) from a past epoch to `to`.
    /// @dev Critical action => governance-only.
    function sweepDust(uint64 epoch, address to) external nonReentrant {
        _requireGovernance();
        if (to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();

        Round storage r = _rounds[epoch];
        if (!r.exists) return;

        uint256 dust = r.remaining;
        if (dust == 0) return;

        r.remaining = 0;
        totalRemaining -= dust;

        SafeERC20.safeTransfer(payoutToken, to, dust);
        emit DustSwept(epoch, to, dust, msg.sender);
    }

    // ------------------------------ Internals -------------------------------

    function _safeTotalSupplyAtEpoch(address sm, uint64 epoch) internal view returns (bool ok, uint256 ts) {
        bytes memory cd = abi.encodeWithSelector(ISnapshotModuleLike.totalSupplyAtEpoch.selector, epoch);
        return SafeStaticCall.tryStaticCallUint256(sm, SNAPSHOT_GAS_STIPEND, cd, SNAPSHOT_MAX_RET);
    }

    function _safeBalanceOfAtEpoch(address sm, address account, uint64 epoch) internal view returns (bool ok, uint256 bal) {
        bytes memory cd = abi.encodeWithSelector(ISnapshotModuleLike.balanceOfAtEpoch.selector, account, epoch);
        return SafeStaticCall.tryStaticCallUint256(sm, SNAPSHOT_GAS_STIPEND, cd, SNAPSHOT_MAX_RET);
    }

    function _setSnapshotModuleInternal(address newModule, bytes32 expectedCampaignId) internal {
        if (newModule == address(0) || newModule.code.length == 0) revert InsurancePool__InvalidSnapshotModule();

        // Ensure module is bound to the same campaignId (defensive wiring).
        bytes32 cid = ISnapshotModuleLike(newModule).campaignId();
        if (cid != expectedCampaignId) revert InsurancePool__InvalidCampaignId();

        address old = snapshotModule;
        snapshotModule = newModule;
        emit SnapshotModuleSet(old, newModule);
    }

    function _setDisasterModuleInternal(address newModule) internal {
        if (newModule == address(0) || newModule.code.length == 0) revert InsurancePool__InvalidDisasterModule();
        address old = disasterModule;
        disasterModule = newModule;
        emit DisasterModuleSet(old, newModule);
    }

    function _setPayoutTokenInternal(address newToken) internal {
        if (newToken == address(0) || newToken.code.length == 0) revert InsurancePool__InvalidPayoutToken();
        address old = payoutToken;
        payoutToken = newToken;
        emit PayoutTokenSet(old, newToken);
    }

    function _requireDisasterConfirmed() internal view {
        address dm = disasterModule;
        if (dm == address(0) || dm.code.length == 0) revert InsurancePool__InvalidDisasterModule();

        IAgriDisasterAdminV1.DisasterState memory st = IAgriDisasterAdminV1(dm).getDisaster(campaignId);
        if (!st.confirmed) revert InsurancePool__DisasterNotConfirmed(campaignId);
    }

    // ------------------------------ RBAC ------------------------------------

    function _requireGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) || rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller)) {
            return;
        }
        revert UAgriErrors.UAgri__Unauthorized();
    }

    function _requireGuardianOrGovernance() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) ||
            rm.hasRole(UAgriRoles.GUARDIAN_ROLE, caller)
        ) {
            return;
        }
        revert UAgriErrors.UAgri__Unauthorized();
    }
}
