// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {AgriShareToken} from "src/core/AgriShareToken.sol";

import {IERC165, IERC7943Fungible} from "src/interfaces/v1/IERC7943Fungible.sol";
import {IAgriModulesV1} from "src/interfaces/v1/IAgriModulesV1.sol";
import {IAgriComplianceV1} from "src/interfaces/v1/IAgriComplianceV1.sol";
import {IAgriDisasterV1} from "src/interfaces/v1/IAgriDisasterV1.sol";
import {IAgriFreezeV1} from "src/interfaces/v1/IAgriFreezeV1.sol";

import {UAgriTypes} from "src/interfaces/constants/UAgriTypes.sol";
import {UAgriErrors} from "src/interfaces/constants/UAgriErrors.sol";
import {UAgriFlags} from "src/interfaces/constants/UAgriFlags.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";

contract CovTokenCompliance is IAgriComplianceV1 {
    bool public defaultCanTransact = true;
    bool public canTransferResult = true;
    bool public revertCanTransact;
    bool public revertCanTransfer;

    mapping(address => bool) public canTransactByAccount;
    mapping(address => bool) public hasCustomCanTransact;

    function setCanTransact(address account, bool ok) external {
        canTransactByAccount[account] = ok;
        hasCustomCanTransact[account] = true;
    }

    function setDefaultCanTransact(bool ok) external {
        defaultCanTransact = ok;
    }

    function setCanTransferResult(bool ok) external {
        canTransferResult = ok;
    }

    function setReverts(bool txReverts, bool transferReverts) external {
        revertCanTransact = txReverts;
        revertCanTransfer = transferReverts;
    }

    function canTransact(address account) external view returns (bool ok) {
        if (revertCanTransact) revert("TX_FAIL");
        if (hasCustomCanTransact[account]) return canTransactByAccount[account];
        return defaultCanTransact;
    }

    function canTransfer(address, address, uint256) external view returns (bool ok) {
        if (revertCanTransfer) revert("TRANSFER_FAIL");
        return canTransferResult;
    }

    function transferStatus(address, address, uint256) external view returns (bool ok, uint8 code) {
        return (canTransferResult, canTransferResult ? 0 : 1);
    }
}

contract CovTokenDisaster is IAgriDisasterV1 {
    uint256 public flags;
    bool public shouldRevert;

    function setState(uint256 f, bool reverts) external {
        flags = f;
        shouldRevert = reverts;
    }

    function campaignFlags(bytes32) external view returns (uint256) {
        if (shouldRevert) revert("FLAGS_FAIL");
        return flags;
    }

    function isRestricted(bytes32) external pure returns (bool) {
        return false;
    }

    function isHardFrozen(bytes32) external pure returns (bool) {
        return false;
    }
}

contract CovTokenFreeze is IAgriFreezeV1 {
    address public override token;
    address public override roleManager;
    bool public revertGetFrozen;

    mapping(address => uint256) public frozen;

    constructor(address rm) {
        roleManager = rm;
    }

    function setRevertGetFrozen(bool v) external {
        revertGetFrozen = v;
    }

    function setToken(address newToken) external {
        token = newToken;
    }

    function getFrozenTokens(address account) external view returns (uint256) {
        if (revertGetFrozen) revert("FROZEN_FAIL");
        return frozen[account];
    }

    function setFrozenTokensFromToken(address account, uint256 frozenAmount) external {
        frozen[account] = frozenAmount;
    }

    function setFrozenTokensBatchFromToken(address[] calldata accounts, uint256[] calldata frozenAmounts) external {
        uint256 n = accounts.length;
        require(n == frozenAmounts.length, "LEN");
        for (uint256 i; i < n; ) {
            frozen[accounts[i]] = frozenAmounts[i];
            unchecked {
                ++i;
            }
        }
    }

    function setFrozenTokens(address account, uint256 frozenAmount) external {
        frozen[account] = frozenAmount;
    }

    function setFrozenTokensBatch(address[] calldata accounts, uint256[] calldata frozenAmounts) external {
        uint256 n = accounts.length;
        require(n == frozenAmounts.length, "LEN");
        for (uint256 i; i < n; ) {
            frozen[accounts[i]] = frozenAmounts[i];
            unchecked {
                ++i;
            }
        }
    }
}

contract CovTokenDistribution {
    uint8 public mode; // 0 ok, 1 revert("HOOK_FAIL"), 2 revert()
    uint256 public mintCalls;
    uint256 public burnCalls;
    uint256 public transferCalls;

    function setMode(uint8 m) external {
        mode = m;
    }

    function onMint(address, uint256) external {
        mintCalls += 1;
        _maybeRevert();
    }

    function onBurn(address, uint256) external {
        burnCalls += 1;
        _maybeRevert();
    }

    function onTransfer(address, address, uint256) external {
        transferCalls += 1;
        _maybeRevert();
    }

    function _maybeRevert() internal view {
        if (mode == 1) revert("HOOK_FAIL");
        if (mode == 2) {
            revert();
        }
    }
}

contract CovForcedTransferController {
    uint256 public frozenBeforeResult;
    uint256 public frozenAfterResult;
    bool public shouldRevert;

    function setResponse(uint256 before_, uint256 after_, bool reverts) external {
        frozenBeforeResult = before_;
        frozenAfterResult = after_;
        shouldRevert = reverts;
    }

    function preForcedTransfer(address, address, address, uint256, uint256)
        external
        view
        returns (uint256 frozenBefore, uint256 frozenAfter)
    {
        if (shouldRevert) revert("FORCED_FAIL");
        return (frozenBeforeResult, frozenAfterResult);
    }
}

contract TokenCoverageTest is Test {
    RoleManager internal rm;
    AgriShareToken internal token;

    CovTokenCompliance internal compliance;
    CovTokenDisaster internal disaster;
    CovTokenFreeze internal freeze;
    CovTokenDistribution internal distribution;
    CovForcedTransferController internal forcedController;

    bytes32 internal campaignId = keccak256("token-coverage");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal operator = makeAddr("operator");
    address internal treasury = makeAddr("treasury");
    address internal regulator = makeAddr("regulator");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        rm = new RoleManager(address(this));
        rm.grantRole(UAgriRoles.FARM_OPERATOR_ROLE, operator);
        rm.grantRole(UAgriRoles.TREASURY_ADMIN_ROLE, treasury);
        rm.grantRole(UAgriRoles.REGULATOR_ENFORCER_ROLE, regulator);

        compliance = new CovTokenCompliance();
        disaster = new CovTokenDisaster();
        freeze = new CovTokenFreeze(address(rm));
        distribution = new CovTokenDistribution();
        forcedController = new CovForcedTransferController();

        UAgriTypes.ViewGasLimits memory viewGas = UAgriTypes.ViewGasLimits({
            complianceGas: 100_000,
            disasterGas: 80_000,
            freezeGas: 80_000,
            custodyGas: 60_000,
            extraGas: 40_000
        });

        token = new AgriShareToken(
            address(rm),
            campaignId,
            "Coverage Token",
            "COV",
            6,
            _modules(address(distribution)),
            address(forcedController),
            viewGas
        );

        freeze.setToken(address(token));
    }

    function testTokenViewsAndGovernanceSettersAndInitGuard() public {
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertTrue(token.supportsInterface(type(IERC7943Fungible).interfaceId));
        assertTrue(token.supportsInterface(type(IAgriModulesV1).interfaceId));
        assertFalse(token.supportsInterface(bytes4(0xFFFFFFFF)));

        assertEq(token.complianceModule(), address(compliance));
        assertEq(token.disasterModule(), address(disaster));
        assertEq(token.freezeModule(), address(freeze));
        assertEq(token.custodyModule(), address(0));
        assertEq(token.traceModule(), address(0));
        assertEq(token.documentRegistry(), address(0));
        assertEq(token.settlementQueue(), address(0));
        assertEq(token.treasury(), address(0));
        assertEq(token.distribution(), address(distribution));
        assertEq(token.bridgeModule(), address(0));
        assertEq(token.marketplaceModule(), address(0));
        assertEq(token.deliveryModule(), address(0));
        assertEq(token.insuranceModule(), address(0));

        token.approve(bob, 55);
        assertEq(token.allowance(address(this), bob), 55);

        UAgriTypes.ViewGasLimits memory limits;
        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        token.setViewGasLimits(limits);

        token.setViewGasLimits(limits); // all zero => defaults
        UAgriTypes.ViewGasLimits memory got = token.viewGasLimits();
        assertEq(got.complianceGas, 50_000);
        assertEq(got.disasterGas, 30_000);
        assertEq(got.freezeGas, 30_000);
        assertEq(got.custodyGas, 30_000);
        assertEq(got.extraGas, 30_000);

        IAgriModulesV1.ModulesV1 memory badMods = _modules(address(distribution));
        badMods.compliance = address(0);
        vm.expectRevert(AgriShareToken.AgriShareToken__InvalidModule.selector);
        token.setModulesV1(badMods);

        vm.expectRevert(AgriShareToken.AgriShareToken__InvalidModule.selector);
        token.setForcedTransferController(address(0));

        token.setDistributionHooksConfig(true, false, 123_456);
        token.setDistributionHooksConfig(true, false, 0);
        assertEq(token.distributionHookGasLimit(), 123_456);

        UAgriTypes.ViewGasLimits memory vg = UAgriTypes.ViewGasLimits({
            complianceGas: 1,
            disasterGas: 2,
            freezeGas: 3,
            custodyGas: 4,
            extraGas: 5
        });
        vm.expectRevert(AgriShareToken.AgriShareToken__AlreadyInitialized.selector);
        token.initialize(
            address(rm),
            campaignId,
            "Again",
            "AGAIN",
            18,
            _modules(address(distribution)),
            address(forcedController),
            vg
        );
    }

    function testTransferStatusCodesAndViews() public {
        token.setDistributionHooksConfig(false, false, 0);
        token.mint(alice, 100);

        freeze.setFrozenTokens(alice, 90);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgriShareToken.AgriShareToken__InsufficientUnfrozen.selector, 10, 20));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 20);

        freeze.setFrozenTokens(alice, 0);
        compliance.setCanTransact(alice, false);
        vm.prank(alice);
        vm.expectRevert(UAgriErrors.UAgri__ComplianceDenied.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 1);

        compliance.setCanTransact(alice, true);
        compliance.setCanTransact(bob, false);
        vm.prank(alice);
        vm.expectRevert(UAgriErrors.UAgri__ComplianceDenied.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 1);

        compliance.setCanTransact(bob, true);
        compliance.setCanTransferResult(false);
        vm.prank(alice);
        vm.expectRevert(UAgriErrors.UAgri__ComplianceDenied.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 1);

        compliance.setCanTransferResult(true);
        disaster.setState(UAgriFlags.PAUSE_TRANSFERS, false);
        vm.prank(alice);
        vm.expectRevert(UAgriErrors.UAgri__Paused.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 1);

        disaster.setState(0, true);
        vm.prank(alice);
        vm.expectRevert(UAgriErrors.UAgri__FailClosed.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 1);

        disaster.setState(0, false);
        freeze.setRevertGetFrozen(true);
        vm.prank(alice);
        vm.expectRevert(UAgriErrors.UAgri__FailClosed.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 1);

        freeze.setRevertGetFrozen(true);
        assertEq(token.getFrozenTokens(alice), token.balanceOf(alice));

        freeze.setRevertGetFrozen(false);
        assertEq(token.getFrozenTokens(alice), 0);

        vm.prank(alice);
        bool ok = token.transfer(bob, 0);
        assertTrue(ok);
        assertFalse(token.canTransact(address(0)));

        disaster.setState(UAgriFlags.PAUSE_TRANSFERS, false);
        assertFalse(token.canTransact(alice));

        disaster.setState(0, false);
        compliance.setCanTransact(alice, false);
        assertFalse(token.canTransact(alice));

        compliance.setCanTransact(alice, true);
        assertTrue(token.canTransact(alice));
        assertFalse(token.canTransfer(address(0), bob, 1));
    }

    function testSetFrozenAndForcedTransferPaths() public {
        token.setDistributionHooksConfig(false, false, 0);
        token.mint(alice, 100);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        token.setFrozenTokens(alice, 1);

        vm.prank(regulator);
        token.setFrozenTokens(alice, 33);
        assertEq(freeze.frozen(alice), 33);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        token.forcedTransfer(address(0), bob, 1);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAmount.selector);
        token.forcedTransfer(alice, bob, 0);

        vm.expectRevert(abi.encodeWithSelector(AgriShareToken.AgriShareToken__InsufficientBalance.selector, 100, 101));
        token.forcedTransfer(alice, bob, 101);

        forcedController.setResponse(33, 20, false);
        vm.prank(regulator);
        token.forcedTransfer(alice, bob, 40);

        assertEq(token.balanceOf(alice), 60);
        assertEq(token.balanceOf(bob), 40);
        assertEq(freeze.frozen(alice), 20);
    }

    function testHookFailureModesAndBubbleRevert() public {
        IAgriModulesV1.ModulesV1 memory eoaMods = _modules(makeAddr("dist-eoa"));
        token.setModulesV1(eoaMods);
        token.setDistributionHooksConfig(true, false, 200_000);

        vm.expectRevert(AgriShareToken.AgriShareToken__InvalidModule.selector);
        token.mint(alice, 1);

        token.setDistributionHooksConfig(true, true, 200_000);
        token.mint(alice, 1);

        token.setModulesV1(_modules(address(distribution)));
        distribution.setMode(1);
        token.setDistributionHooksConfig(true, true, 200_000);
        token.mint(alice, 1);

        token.setDistributionHooksConfig(true, false, 200_000);
        vm.expectRevert(bytes("HOOK_FAIL"));
        token.mint(alice, 1);

        distribution.setMode(2);
        vm.expectRevert(UAgriErrors.UAgri__FailClosed.selector);
        token.mint(alice, 1);
    }

    function testMintBurnAllowanceAndRoleGuards() public {
        token.setDistributionHooksConfig(false, false, 0);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        token.mint(alice, 1);

        disaster.setState(UAgriFlags.PAUSE_FUNDING, false);
        vm.prank(operator);
        vm.expectRevert(UAgriErrors.UAgri__Paused.selector);
        token.mint(alice, 1);

        disaster.setState(0, false);
        compliance.setCanTransact(alice, false);
        vm.prank(operator);
        vm.expectRevert(UAgriErrors.UAgri__ComplianceDenied.selector);
        token.mint(alice, 1);

        compliance.setCanTransact(alice, true);
        vm.prank(operator);
        token.mint(alice, 50);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgriShareToken.AgriShareToken__InsufficientAllowance.selector, 0, 1));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(alice, bob, 1);

        vm.prank(alice);
        token.approve(bob, 10);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 4));
        assertEq(token.balanceOf(bob), 4);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        token.burn(alice, 1);

        disaster.setState(UAgriFlags.PAUSE_REDEMPTIONS, false);
        vm.prank(operator);
        vm.expectRevert(UAgriErrors.UAgri__Paused.selector);
        token.burn(alice, 1);

        disaster.setState(0, false);
        vm.prank(operator);
        vm.expectRevert(UAgriErrors.UAgri__InvalidAmount.selector);
        token.burn(alice, 0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AgriShareToken.AgriShareToken__InsufficientBalance.selector, 46, 100));
        token.burn(alice, 100);

        vm.prank(operator);
        token.burn(alice, 10);
        assertEq(token.balanceOf(alice), 36);

        vm.prank(treasury);
        token.mint(bob, 5);
        assertEq(token.balanceOf(bob), 9);
    }

    function _modules(address distributionModule) internal view returns (IAgriModulesV1.ModulesV1 memory m) {
        m = IAgriModulesV1.ModulesV1({
            compliance: address(compliance),
            disaster: address(disaster),
            freezeModule: address(freeze),
            custody: address(0),
            trace: address(0),
            documentRegistry: address(0),
            settlementQueue: address(0),
            treasury: address(0),
            distribution: distributionModule,
            bridge: address(0),
            marketplace: address(0),
            delivery: address(0),
            insurance: address(0)
        });
    }
}
