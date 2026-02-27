// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ISettlementQueueV1} from "../interfaces/v1/ISettlementQueueV1.sol";
import {UAgriTypes} from "../interfaces/constants/UAgriTypes.sol";
import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

import {RoleManager} from "../access/RoleManager.sol";
import {ReentrancyGuard} from "../_shared/ReentrancyGuard.sol";

/// @dev Minimal interface to call FundingManager from the queue.
interface IFundingManagerQueueV1 {
    /// @notice Settle a request by pulling its data from the queue.
    /// @dev Must revert on invalid/expired/bad-state requests. Returns "outAmount"
    ///      to be emitted by the queue in RequestProcessed.
    function settleFromQueue(
        uint256 requestId,
        bytes32 ref
    ) external returns (uint256 outAmount);
}

/// @title SettlementQueue
/// @notice Request intake + batch processing for a single campaign.
/// @dev Stores UAgriTypes.Request and processes them by calling FundingManager.settleFromQueue().
///      This queue is "funds-agnostic": it does not custody tokens; it only records intents.
///
/// Deposit convention for ISettlementQueueV1.requestDeposit(amountIn, maxIn, deadline):
/// - If depositExactSharesMode == false (default):
///     amountIn = assetsIn
///     maxIn    = minSharesOut     => stored in Request.minOut
///     Request.maxIn = 0
/// - If depositExactSharesMode == true:
///     amountIn = sharesDesired
///     maxIn    = maxAssetsIn      => stored in Request.maxIn
///     Request.minOut = 0
///
/// This matches FundingManager.settleFromQueue() logic (dual-mode via r.maxIn != 0).
contract SettlementQueue is ISettlementQueueV1, ReentrancyGuard {
    // ------------------------------- Storage ---------------------------------

    RoleManager public roleManager;
    bytes32 public campaignId;

    /// @notice FundingManager that will be called during batch processing.
    address public fundingManager;

    /// @notice Monotonic request counter. Request IDs are 1..requestCount.
    uint256 private _requestCount;

    /// @notice Requests by id.
    mapping(uint256 => UAgriTypes.Request) private _requests;

    /// @notice Deposit request mode toggle (see contract header comment).
    bool public depositExactSharesMode;

    bool private _initialized;

    // ------------------------------- Extra Events ----------------------------

    event FundingManagerUpdated(address indexed fundingManager);
    event DepositModeUpdated(bool depositExactSharesMode);

    /// @dev Extra operational signal: batch didn't revert, but a given request failed to settle.
    event RequestFailed(
        uint256 indexed id,
        address indexed account,
        UAgriTypes.RequestKind kind,
        uint256 amount,
        bytes revertData
    );

    // ------------------------------- Errors ----------------------------------

    error SettlementQueue__AlreadyInitialized();
    error SettlementQueue__InvalidRoleManager();
    error SettlementQueue__InvalidCampaignId();
    error SettlementQueue__InvalidFundingManager();

    // -------------------------------- Modifiers ------------------------------

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    modifier onlyProcessor() {
        _requireProcessor();
        _;
    }

    // ------------------------------ Init / Config ----------------------------

    constructor(
        address roleManager_,
        bytes32 campaignId_,
        address fundingManager_,
        bool depositExactSharesMode_
    ) {
        _init(
            roleManager_,
            campaignId_,
            fundingManager_,
            depositExactSharesMode_
        );
    }

    function initialize(
        address roleManager_,
        bytes32 campaignId_,
        address fundingManager_,
        bool depositExactSharesMode_
    ) external {
        _init(
            roleManager_,
            campaignId_,
            fundingManager_,
            depositExactSharesMode_
        );
    }

    function _init(
        address roleManager_,
        bytes32 campaignId_,
        address fundingManager_,
        bool depositExactSharesMode_
    ) internal {
        if (_initialized) revert SettlementQueue__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0))
            revert SettlementQueue__InvalidRoleManager();
        if (campaignId_ == bytes32(0))
            revert SettlementQueue__InvalidCampaignId();
        if (fundingManager_ == address(0))
            revert SettlementQueue__InvalidFundingManager();

        roleManager = RoleManager(roleManager_);
        campaignId = campaignId_;
        fundingManager = fundingManager_;
        depositExactSharesMode = depositExactSharesMode_;

        emit FundingManagerUpdated(fundingManager_);
        emit DepositModeUpdated(depositExactSharesMode_);
    }

    // ------------------------------ Governance --------------------------------

    function setFundingManager(
        address fundingManager_
    ) external onlyGovernance {
        if (fundingManager_ == address(0))
            revert SettlementQueue__InvalidFundingManager();
        fundingManager = fundingManager_;
        emit FundingManagerUpdated(fundingManager_);
    }

    function setDepositExactSharesMode(bool enabled) external onlyGovernance {
        depositExactSharesMode = enabled;
        emit DepositModeUpdated(enabled);
    }

    // -------------------------- Convenience (optional) -------------------------

    /// @notice Explicit deposit intent: exact assets in, min shares out (independent of depositExactSharesMode).
    function requestDepositExactAssets(
        uint256 assetsIn,
        uint256 minSharesOut,
        uint64 deadline
    ) external returns (uint256 id) {
        if (assetsIn == 0) revert UAgriErrors.UAgri__InvalidAmount();
        if (deadline != 0 && uint64(block.timestamp) > deadline)
            revert UAgriErrors.UAgri__DeadlineExpired();

        id = _createRequest(
            msg.sender,
            UAgriTypes.RequestKind.Deposit,
            assetsIn,
            minSharesOut,
            0,
            deadline
        );
    }

    /// @notice Explicit deposit intent: exact shares out, max assets in (independent of depositExactSharesMode).
    function requestDepositExactShares(
        uint256 sharesDesired,
        uint256 maxAssetsIn,
        uint64 deadline
    ) external returns (uint256 id) {
        if (sharesDesired == 0) revert UAgriErrors.UAgri__InvalidAmount();
        if (maxAssetsIn == 0) revert UAgriErrors.UAgri__InvalidAmount();
        if (deadline != 0 && uint64(block.timestamp) > deadline)
            revert UAgriErrors.UAgri__DeadlineExpired();

        id = _createRequest(
            msg.sender,
            UAgriTypes.RequestKind.Deposit,
            sharesDesired,
            0,
            maxAssetsIn,
            deadline
        );
    }

    /// @notice Convenience view: total requests created so far.
    function requestCount() external view returns (uint256) {
        return _requestCount;
    }

    // --------------------------- ISettlementQueueV1 ---------------------------

    function requestDeposit(
        uint256 amountIn,
        uint256 maxIn,
        uint64 deadline
    ) external override returns (uint256 id) {
        if (amountIn == 0) revert UAgriErrors.UAgri__InvalidAmount();
        if (deadline != 0 && uint64(block.timestamp) > deadline)
            revert UAgriErrors.UAgri__DeadlineExpired();

        // Overloaded param semantics controlled by depositExactSharesMode
        if (depositExactSharesMode) {
            // exact-shares mode:
            // amountIn = sharesDesired
            // maxIn    = maxAssetsIn
            if (maxIn == 0) revert UAgriErrors.UAgri__InvalidAmount();
            id = _createRequest(
                msg.sender,
                UAgriTypes.RequestKind.Deposit,
                amountIn,
                0,
                maxIn,
                deadline
            );
        } else {
            // common mode:
            // amountIn = assetsIn
            // maxIn    = minSharesOut (stored into minOut)
            id = _createRequest(
                msg.sender,
                UAgriTypes.RequestKind.Deposit,
                amountIn,
                maxIn,
                0,
                deadline
            );
        }
    }

    function requestRedeem(
        uint256 shares,
        uint256 minOut,
        uint64 deadline
    ) external override returns (uint256 id) {
        if (shares == 0) revert UAgriErrors.UAgri__InvalidAmount();
        if (deadline != 0 && uint64(block.timestamp) > deadline)
            revert UAgriErrors.UAgri__DeadlineExpired();

        // Redeem is always: amount=sharesIn, minOut=minAssetsOut, maxIn=0
        id = _createRequest(
            msg.sender,
            UAgriTypes.RequestKind.Redeem,
            shares,
            minOut,
            0,
            deadline
        );
    }

    function cancel(uint256 id) external override nonReentrant {
        UAgriTypes.Request storage r = _requests[id];
        if (r.status == UAgriTypes.RequestStatus.None)
            revert UAgriErrors.UAgri__RequestNotFound();
        if (r.status != UAgriTypes.RequestStatus.Requested)
            revert UAgriErrors.UAgri__RequestNotCancellable();

        // Allow: requester OR processor/governance actors
        if (msg.sender != r.account) {
            _requireProcessor();
        }

        r.status = UAgriTypes.RequestStatus.Cancelled;
        emit RequestCancelled(id, msg.sender);
    }

    function getRequest(
        uint256 id
    ) external view override returns (UAgriTypes.Request memory r) {
        r = _requests[id];
        if (r.status == UAgriTypes.RequestStatus.None)
            revert UAgriErrors.UAgri__RequestNotFound();
    }

    /// @notice Batch process ids; best-effort: a single failing request does NOT revert the whole batch.
    /// @dev Still reverts on: missing request id (None) or invalid queue config (no fundingManager).
    function batchProcess(
        uint256[] calldata ids,
        uint64 epoch,
        bytes32 reportHash
    ) external override nonReentrant onlyProcessor {
        address fm = fundingManager;
        if (fm == address(0)) revert SettlementQueue__InvalidFundingManager();

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];

            UAgriTypes.Request storage r = _requests[id];
            if (r.status == UAgriTypes.RequestStatus.None)
                revert UAgriErrors.UAgri__RequestNotFound();
            if (r.status != UAgriTypes.RequestStatus.Requested) continue;

            if (r.deadline != 0 && uint64(block.timestamp) > r.deadline) {
                r.status = UAgriTypes.RequestStatus.Cancelled;
                emit RequestCancelled(id, r.account);
                continue;
            }

            // Mark processed BEFORE external call (reentrancy hardening).
            r.status = UAgriTypes.RequestStatus.Processed;

            // Best-effort settlement
            try
                IFundingManagerQueueV1(fm).settleFromQueue(
                    id,
                    keccak256(abi.encodePacked(epoch, reportHash, id))
                )
            returns (uint256 outAmount) {
                emit RequestProcessed(
                    id,
                    r.account,
                    r.kind,
                    r.amount,
                    outAmount,
                    epoch,
                    reportHash
                );
            } catch (bytes memory data) {
                r.status = UAgriTypes.RequestStatus.Requested;
                emit RequestFailed(id, r.account, r.kind, r.amount, data);
            }
        }
    }

    // ------------------------------ Internals --------------------------------

    function _createRequest(
        address account,
        UAgriTypes.RequestKind kind,
        uint256 amount,
        uint256 minOut,
        uint256 maxIn,
        uint64 deadline
    ) internal returns (uint256 id) {
        id = ++_requestCount;

        UAgriTypes.Request storage r = _requests[id];
        r.account = account;
        r.kind = kind;
        r.amount = amount;
        r.minOut = minOut;
        r.maxIn = maxIn;
        r.deadline = deadline;
        r.status = UAgriTypes.RequestStatus.Requested;

        emit RequestCreated(id, account, kind, amount, minOut, maxIn, deadline);
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

    function _requireProcessor() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.FARM_OPERATOR_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.TREASURY_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.GOVERNANCE_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller)
        ) revert UAgriErrors.UAgri__Unauthorized();
    }
}
