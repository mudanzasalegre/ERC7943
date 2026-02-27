// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC165, IERC7943Fungible} from "../interfaces/v1/IERC7943Fungible.sol";
import {IAgriModulesV1} from "../interfaces/v1/IAgriModulesV1.sol";
import {IAgriComplianceV1} from "../interfaces/v1/IAgriComplianceV1.sol";
import {IAgriDisasterV1} from "../interfaces/v1/IAgriDisasterV1.sol";
import {IAgriFreezeV1} from "../interfaces/v1/IAgriFreezeV1.sol";

import {UAgriTypes} from "../interfaces/constants/UAgriTypes.sol";
import {UAgriErrors} from "../interfaces/constants/UAgriErrors.sol";
import {UAgriFlags} from "../interfaces/constants/UAgriFlags.sol";
import {UAgriRoles} from "../interfaces/constants/UAgriRoles.sol";

import {RoleManager} from "../access/RoleManager.sol";
import {SafeStaticCall} from "../_shared/SafeStaticCall.sol";
import {ReentrancyGuard} from "../_shared/ReentrancyGuard.sol";

/// @dev Hook interface for forced-transfer policy modules.
interface IAgriForcedTransferV1 {
    function preForcedTransfer(
        address actor,
        address from,
        address to,
        uint256 amount,
        uint256 balanceBefore
    ) external view returns (uint256 frozenBefore, uint256 frozenAfter);
}

/// @dev Distribution hook interface (implemented by YieldAccumulator).
interface IAgriDistributionHooksV1 {
    function onMint(address to, uint256 amount) external;
    function onBurn(address from, uint256 amount) external;
    function onTransfer(address from, address to, uint256 amount) external;
}

/// @title AgriShareToken
/// @notice ERC-20 campaign shares with ERC-7943 enforcement (no-revert views + fail-closed).
/// @dev External module calls are gas-capped and fail-closed for policy modules.
///      Distribution hooks are configurable (fail-closed by default).
contract AgriShareToken is IERC7943Fungible, IAgriModulesV1, ReentrancyGuard {
    // ------------------------------- ERC-20 ----------------------------------

    string public name;
    string public symbol;
    uint8 private _decimals;

    uint256 public totalSupply;

    mapping(address => uint256) private _balanceOf;
    mapping(address => mapping(address => uint256)) private _allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    // ------------------------------- Config ----------------------------------

    RoleManager public roleManager;
    bytes32 public campaignId;

    bool private _initialized;

    /// @notice Optional policy hook for judicial/regulated forced transfers.
    address public forcedTransferController;

    IAgriModulesV1.ModulesV1 private _mods;
    UAgriTypes.ViewGasLimits private _viewGas;

    event ForcedTransferControllerUpdated(address indexed controller);

    // -------------------------- Distribution hooks config ---------------------

    /// @notice Enable/disable calling distribution hooks (onMint/onBurn/onTransfer).
    bool public distributionHooksEnabled;

    /// @notice If true, hook failures won't revert token ops (emits event).
    bool public distributionHooksFailOpen;

    /// @notice Gas cap for hook calls (separate from viewGasLimits).
    uint32 public distributionHookGasLimit;

    event DistributionHooksConfigUpdated(
        bool enabled,
        bool failOpen,
        uint32 gasLimit
    );

    event DistributionHookCallFailed(bytes4 indexed selector, bytes32 revertHash);

    // -------------------------------- Errors ---------------------------------
    error AgriShareToken__AlreadyInitialized();
    error AgriShareToken__InvalidRoleManager();
    error AgriShareToken__InvalidCampaignId();
    error AgriShareToken__InvalidModule();
    error AgriShareToken__InsufficientBalance(uint256 balance, uint256 amount);
    error AgriShareToken__InsufficientAllowance(uint256 allowance, uint256 amount);
    error AgriShareToken__InsufficientUnfrozen(uint256 unfrozen, uint256 amount);

    bytes32 private constant _MODULES_UPDATED_EVENT_SIG =
        0x2c89089ec9a5d86a3e0999cfd9a165650f183311394a357064e1f805dcd641b1;

    // -------------------------------- Modifiers ------------------------------
    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    // ----------------------------- Init / Configure --------------------------

    constructor(
        address roleManager_,
        bytes32 campaignId_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        IAgriModulesV1.ModulesV1 memory modules_,
        address forcedTransferController_,
        UAgriTypes.ViewGasLimits memory viewGas_
    ) {
        _init(roleManager_, campaignId_, name_, symbol_, decimals_, modules_, forcedTransferController_, viewGas_);
    }

    function initialize(
        address roleManager_,
        bytes32 campaignId_,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        IAgriModulesV1.ModulesV1 calldata modules_,
        address forcedTransferController_,
        UAgriTypes.ViewGasLimits calldata viewGas_
    ) external {
        _init(roleManager_, campaignId_, name_, symbol_, decimals_, modules_, forcedTransferController_, viewGas_);
    }

    function _init(
        address roleManager_,
        bytes32 campaignId_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        IAgriModulesV1.ModulesV1 memory modules_,
        address forcedTransferController_,
        UAgriTypes.ViewGasLimits memory viewGas_
    ) internal {
        if (_initialized) revert AgriShareToken__AlreadyInitialized();
        _initialized = true;

        if (roleManager_ == address(0)) revert AgriShareToken__InvalidRoleManager();
        if (campaignId_ == bytes32(0)) revert AgriShareToken__InvalidCampaignId();

        roleManager = RoleManager(roleManager_);
        campaignId = campaignId_;

        _setTokenMetadata(name_, symbol_, decimals_);

        _setModulesInternal(modules_);
        _setForcedTransferControllerInternal(forcedTransferController_);
        _setViewGasLimitsInternal(viewGas_);

        // sensible defaults for hooks
        _setDistributionHookDefaults();
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    // ----------------------------- ERC-165 / 7943 -----------------------------

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        override(IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC7943Fungible).interfaceId ||
            interfaceId == type(IAgriModulesV1).interfaceId;
    }

    // --------------------------- IAgriModulesV1 views -------------------------

    function complianceModule() external view returns (address) { return _mods.compliance; }
    function disasterModule() external view returns (address) { return _mods.disaster; }
    function freezeModule() external view returns (address) { return _mods.freezeModule; }
    function custodyModule() external view returns (address) { return _mods.custody; }

    function traceModule() external view returns (address) { return _mods.trace; }
    function documentRegistry() external view returns (address) { return _mods.documentRegistry; }

    function settlementQueue() external view returns (address) { return _mods.settlementQueue; }
    function treasury() external view returns (address) { return _mods.treasury; }
    function distribution() external view returns (address) { return _mods.distribution; }

    function bridgeModule() external view returns (address) { return _mods.bridge; }
    function marketplaceModule() external view returns (address) { return _mods.marketplace; }
    function deliveryModule() external view returns (address) { return _mods.delivery; }
    function insuranceModule() external view returns (address) { return _mods.insurance; }

    function viewGasLimits() external view returns (UAgriTypes.ViewGasLimits memory limits) {
        return _viewGas;
    }

    // --------------------------- IAgriModulesV1 admin -------------------------

    function setViewGasLimits(UAgriTypes.ViewGasLimits calldata limits) external onlyGovernance {
        _setViewGasLimitsInternal(limits);
    }

    /// @notice Convenience setter (non-normative) to update module wiring post-deploy.
    function setModulesV1(IAgriModulesV1.ModulesV1 calldata modules_) external onlyGovernance {
        _setModulesInternal(modules_);
    }

    /// @notice Convenience setter (non-normative) to update the forced transfer controller.
    function setForcedTransferController(address controller) external onlyGovernance {
        _setForcedTransferControllerInternal(controller);
    }

    /// @notice Configure distribution hook behavior.
    function setDistributionHooksConfig(
        bool enabled,
        bool failOpen,
        uint32 gasLimit
    ) external onlyGovernance {
        distributionHooksEnabled = enabled;
        distributionHooksFailOpen = failOpen;

        if (gasLimit != 0) {
            distributionHookGasLimit = gasLimit;
        } else if (distributionHookGasLimit == 0) {
            distributionHookGasLimit = 200_000;
        }

        emit DistributionHooksConfigUpdated(enabled, failOpen, distributionHookGasLimit);
    }

    function _setModulesInternal(IAgriModulesV1.ModulesV1 memory modules_) internal {
        if (modules_.compliance == address(0)) revert AgriShareToken__InvalidModule();
        if (modules_.disaster == address(0)) revert AgriShareToken__InvalidModule();
        if (modules_.freezeModule == address(0)) revert AgriShareToken__InvalidModule();

        _mods = modules_;
        _emitModulesUpdated();
    }

    function _emitModulesUpdated() internal {
        IAgriModulesV1.ModulesV1 memory modules_ = _mods;
        bytes memory data = new bytes(13 * 32);
        assembly {
            let src := modules_
            let dst := add(data, 0x20)
            for { let offset := 0 } lt(offset, 0x1a0) { offset := add(offset, 0x20) } {
                mstore(add(dst, offset), mload(add(src, offset)))
            }
            log1(dst, 0x1a0, _MODULES_UPDATED_EVENT_SIG)
        }
    }

    function _setTokenMetadata(string memory name_, string memory symbol_, uint8 decimals_) internal {
        name = name_;
        symbol = symbol_;
        _decimals = decimals_ == 0 ? 18 : decimals_;
    }

    function _setDistributionHookDefaults() internal {
        distributionHooksEnabled = true;
        distributionHooksFailOpen = false;
        distributionHookGasLimit = 200_000;
        emit DistributionHooksConfigUpdated(
            distributionHooksEnabled,
            distributionHooksFailOpen,
            distributionHookGasLimit
        );
    }

    function _setForcedTransferControllerInternal(address controller) internal {
        if (controller == address(0)) revert AgriShareToken__InvalidModule();
        forcedTransferController = controller;
        emit ForcedTransferControllerUpdated(controller);
    }

    function _setViewGasLimitsInternal(UAgriTypes.ViewGasLimits memory limits) internal {
        if (
            limits.complianceGas == 0 &&
            limits.disasterGas == 0 &&
            limits.freezeGas == 0 &&
            limits.custodyGas == 0 &&
            limits.extraGas == 0
        ) {
            limits = UAgriTypes.ViewGasLimits({
                complianceGas: 50_000,
                disasterGas: 30_000,
                freezeGas: 30_000,
                custodyGas: 30_000,
                extraGas: 30_000
            });
        }
        _viewGas = limits;
        emit ViewGasLimitsUpdated(limits);
    }

    // ------------------------------ ERC-20 views -----------------------------

    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowance[owner][spender];
    }

    // ----------------------------- ERC-20 actions ----------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        uint256 allowed = _allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert AgriShareToken__InsufficientAllowance(allowed, amount);
            unchecked { _allowance[from][msg.sender] = allowed - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        if (owner == address(0) || spender == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        _allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // ---------------------------- Enforcement logic --------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 bal = _enforceTransferPolicy(from, to, amount);

        if (amount == 0) {
            emit Transfer(from, to, 0);
            return;
        }

        if (bal < amount) revert AgriShareToken__InsufficientBalance(bal, amount);

        // distribution hook (snapshot attribution), called before state writes
        _callDistributionOnTransfer(from, to, amount);

        unchecked {
            _balanceOf[from] = bal - amount;
            _balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _enforceTransferPolicy(address from, address to, uint256 amount) internal view returns (uint256 bal) {
        if (from == address(0) || to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();

        (bool flagsOk, uint256 flags) = _safeCampaignFlags();
        if (!flagsOk) revert UAgriErrors.UAgri__FailClosed();
        if ((flags & UAgriFlags.PAUSE_TRANSFERS) != 0) revert UAgriErrors.UAgri__Paused();

        bal = _balanceOf[from];
        (bool frOk, uint256 frozen) = _safeFrozen(from, bal);
        if (!frOk) revert UAgriErrors.UAgri__FailClosed();

        uint256 unfrozen = bal > frozen ? (bal - frozen) : 0;
        if (amount > unfrozen) revert AgriShareToken__InsufficientUnfrozen(unfrozen, amount);

        if (!_safeComplianceCanTransact(from)) revert UAgriErrors.UAgri__ComplianceDenied();
        if (!_safeComplianceCanTransact(to)) revert UAgriErrors.UAgri__ComplianceDenied();
        if (!_safeComplianceCanTransfer(from, to, amount)) revert UAgriErrors.UAgri__ComplianceDenied();
    }

    // ----------------------------- ERC-7943 views ----------------------------

    function getFrozenTokens(address account) external view returns (uint256) {
        uint256 bal = _balanceOf[account];
        (bool ok, uint256 frozen) = _safeFrozen(account, bal);
        if (!ok) return bal;
        return frozen;
    }

    function canTransact(address account) external view returns (bool) {
        if (account == address(0)) return false;

        (bool flagsOk, uint256 flags) = _safeCampaignFlags();
        if (!flagsOk) return false;
        if ((flags & UAgriFlags.PAUSE_TRANSFERS) != 0) return false;

        return _safeComplianceCanTransact(account);
    }

    function canTransfer(address from, address to, uint256 amount) external view returns (bool) {
        if (from == address(0) || to == address(0)) return false;

        (bool flagsOk, uint256 flags) = _safeCampaignFlags();
        if (!flagsOk) return false;
        if ((flags & UAgriFlags.PAUSE_TRANSFERS) != 0) return false;

        uint256 bal = _balanceOf[from];
        (bool frOk, uint256 frozen) = _safeFrozen(from, bal);
        if (!frOk) return false;

        uint256 unfrozen = bal > frozen ? (bal - frozen) : 0;
        if (amount > unfrozen) return false;

        if (!_safeComplianceCanTransact(from)) return false;
        if (!_safeComplianceCanTransact(to)) return false;
        return _safeComplianceCanTransfer(from, to, amount);
    }

    // ------------------------- ERC-7943 admin actions -------------------------

    function setFrozenTokens(address account, uint256 amount) external nonReentrant {
        _requireRegulatorOrAdmin();
        if (account == address(0)) revert UAgriErrors.UAgri__InvalidAddress();

        IAgriFreezeV1(_mods.freezeModule).setFrozenTokensFromToken(account, amount);
        emit Frozen(account, amount);
    }

    function forcedTransfer(address from, address to, uint256 amount) external nonReentrant {
        if (from == address(0) || to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (amount == 0) revert UAgriErrors.UAgri__InvalidAmount();

        uint256 bal = _balanceOf[from];
        if (bal < amount) revert AgriShareToken__InsufficientBalance(bal, amount);

        (uint256 frozenBefore, uint256 frozenAfter) =
            IAgriForcedTransferV1(forcedTransferController).preForcedTransfer(msg.sender, from, to, amount, bal);

        if (frozenAfter != frozenBefore) {
            IAgriFreezeV1(_mods.freezeModule).setFrozenTokensFromToken(from, frozenAfter);
            emit Frozen(from, frozenAfter);
        }

        // distribution hook for forced transfer too
        _callDistributionOnTransfer(from, to, amount);

        unchecked {
            _balanceOf[from] = bal - amount;
            _balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
        emit ForcedTransfer(from, to, amount);
    }

    // -------------------------- Mint / Burn (Ops) ----------------------------

    function mint(address to, uint256 amount) external nonReentrant {
        _requireOperatorOrTreasury();
        if (to == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (amount == 0) revert UAgriErrors.UAgri__InvalidAmount();

        (bool flagsOk, uint256 flags) = _safeCampaignFlags();
        if (!flagsOk) revert UAgriErrors.UAgri__FailClosed();
        if ((flags & UAgriFlags.PAUSE_FUNDING) != 0) revert UAgriErrors.UAgri__Paused();

        if (!_safeComplianceCanTransact(to)) revert UAgriErrors.UAgri__ComplianceDenied();

        // distribution hook (exclude past rewards from newly minted shares)
        _callDistributionOnMint(to, amount);

        totalSupply += amount;
        unchecked { _balanceOf[to] += amount; }
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external nonReentrant {
        _requireOperatorOrTreasury();
        if (from == address(0)) revert UAgriErrors.UAgri__InvalidAddress();
        if (amount == 0) revert UAgriErrors.UAgri__InvalidAmount();

        (bool flagsOk, uint256 flags) = _safeCampaignFlags();
        if (!flagsOk) revert UAgriErrors.UAgri__FailClosed();
        if ((flags & UAgriFlags.PAUSE_REDEMPTIONS) != 0) revert UAgriErrors.UAgri__Paused();

        uint256 bal = _balanceOf[from];
        if (bal < amount) revert AgriShareToken__InsufficientBalance(bal, amount);

        // distribution hook (preserve past rewards for burner)
        _callDistributionOnBurn(from, amount);

        unchecked {
            _balanceOf[from] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // --------------------------- Distribution hook calls ----------------------

    function _callDistributionOnMint(address to, uint256 amount) internal {
        if (!distributionHooksEnabled || amount == 0) return;
        address dist = _mods.distribution;
        if (dist == address(0)) return;

        bytes memory data = abi.encodeWithSelector(IAgriDistributionHooksV1.onMint.selector, to, amount);
        _callDistributionHook(IAgriDistributionHooksV1.onMint.selector, dist, data);
    }

    function _callDistributionOnBurn(address from, uint256 amount) internal {
        if (!distributionHooksEnabled || amount == 0) return;
        address dist = _mods.distribution;
        if (dist == address(0)) return;

        bytes memory data = abi.encodeWithSelector(IAgriDistributionHooksV1.onBurn.selector, from, amount);
        _callDistributionHook(IAgriDistributionHooksV1.onBurn.selector, dist, data);
    }

    function _callDistributionOnTransfer(address from, address to, uint256 amount) internal {
        if (!distributionHooksEnabled || amount == 0) return;
        address dist = _mods.distribution;
        if (dist == address(0)) return;

        bytes memory data = abi.encodeWithSelector(IAgriDistributionHooksV1.onTransfer.selector, from, to, amount);
        _callDistributionHook(IAgriDistributionHooksV1.onTransfer.selector, dist, data);
    }

    function _callDistributionHook(bytes4 selector, address dist, bytes memory data) internal {
        // If it's not a contract => treat as invalid module.
        if (dist.code.length == 0) {
            if (distributionHooksFailOpen) {
                emit DistributionHookCallFailed(selector, bytes32(0));
                return;
            }
            revert AgriShareToken__InvalidModule();
        }

        uint256 gasCap = uint256(distributionHookGasLimit);
        if (gasCap == 0) gasCap = 200_000;

        (bool ok, bytes memory ret) = dist.call{gas: gasCap}(data);
        if (ok) return;

        if (distributionHooksFailOpen) {
            bytes32 h = keccak256(ret);
            emit DistributionHookCallFailed(selector, h);
            return;
        }

        _bubbleRevert(ret);
    }

    function _bubbleRevert(bytes memory ret) internal pure {
        if (ret.length == 0) revert UAgriErrors.UAgri__FailClosed();

        // Bubble standard Error(string) payloads; otherwise fail-closed.
        if (_isErrorString(ret)) {
            bytes memory payload = new bytes(ret.length - 4);
            for (uint256 i = 0; i < payload.length; i++) {
                payload[i] = ret[i + 4];
            }
            string memory reason = abi.decode(payload, (string));
            revert(reason);
        }

        revert UAgriErrors.UAgri__FailClosed();
    }

    function _isErrorString(bytes memory ret) internal pure returns (bool) {
        if (ret.length < 68) return false;
        return
            uint8(ret[0]) == 0x08 &&
            uint8(ret[1]) == 0xc3 &&
            uint8(ret[2]) == 0x79 &&
            uint8(ret[3]) == 0xa0;
    }

    // --------------------------- Safe module calls ---------------------------

    function _safeCampaignFlags() internal view returns (bool ok, uint256 flags) {
        (ok, flags) = SafeStaticCall.tryStaticCallUint256(
            _mods.disaster,
            uint256(_viewGas.disasterGas),
            abi.encodeWithSelector(IAgriDisasterV1.campaignFlags.selector, campaignId),
            0
        );
    }

    function _safeFrozen(address account, uint256 fallbackBalance) internal view returns (bool ok, uint256 frozen) {
        (ok, frozen) = SafeStaticCall.tryStaticCallUint256(
            _mods.freezeModule,
            uint256(_viewGas.freezeGas),
            abi.encodeWithSelector(IAgriFreezeV1.getFrozenTokens.selector, account),
            0
        );
        if (!ok) return (false, fallbackBalance);
        return (true, frozen);
    }

    function _safeComplianceCanTransact(address account) internal view returns (bool) {
        (bool ok, bool allowed) = SafeStaticCall.tryStaticCallBool(
            _mods.compliance,
            uint256(_viewGas.complianceGas),
            abi.encodeWithSelector(IAgriComplianceV1.canTransact.selector, account),
            0
        );
        return ok && allowed;
    }

    function _safeComplianceCanTransfer(address from, address to, uint256 amount) internal view returns (bool) {
        (bool ok, bool allowed) = SafeStaticCall.tryStaticCallBool(
            _mods.compliance,
            uint256(_viewGas.complianceGas),
            abi.encodeWithSelector(IAgriComplianceV1.canTransfer.selector, from, to, amount),
            0
        );
        return ok && allowed;
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

    function _requireRegulatorOrAdmin() internal view {
        RoleManager rm = roleManager;
        address caller = msg.sender;

        if (
            !rm.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, caller) &&
            !rm.hasRole(UAgriRoles.REGULATOR_ENFORCER_ROLE, caller)
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
}
