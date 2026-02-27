// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {ForcedTransferController} from "src/control/ForcedTransferController.sol";
import {FreezeManager} from "src/control/FreezeManager.sol";

import {IAgriFreezeV1} from "src/interfaces/v1/IAgriFreezeV1.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";
import {UAgriErrors} from "src/interfaces/constants/UAgriErrors.sol";

contract CovCtrlFreeze is IAgriFreezeV1 {
    address public override token;
    address public override roleManager;
    mapping(address => uint256) public frozen;

    constructor(address rm) {
        roleManager = rm;
    }

    function setToken(address newToken) external {
        token = newToken;
    }

    function getFrozenTokens(address account) external view returns (uint256) {
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

contract ForcedTransferControllerCoverageTest is Test {
    RoleManager internal rm;
    CovCtrlFreeze internal freeze;
    ForcedTransferController internal controller;

    address internal guardian = makeAddr("guardian");
    address internal enforcer = makeAddr("enforcer");
    address internal outsider = makeAddr("outsider");
    address internal tokenAddr = makeAddr("token");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        rm = new RoleManager(address(this));
        rm.grantRole(UAgriRoles.GUARDIAN_ROLE, guardian);
        rm.grantRole(UAgriRoles.REGULATOR_ENFORCER_ROLE, enforcer);

        freeze = new CovCtrlFreeze(address(rm));
        controller = new ForcedTransferController(address(rm), address(freeze), address(0), false);
    }

    function testControllerAdminAndPreviewPaths() public {
        assertTrue(controller.canForceTransfer(address(this)));
        assertTrue(controller.canForceTransfer(enforcer));
        assertFalse(controller.canForceTransfer(outsider));

        vm.expectRevert(ForcedTransferController.ForcedTransferController__BadInit.selector);
        controller.initialize(address(rm), address(freeze), tokenAddr, true);

        vm.prank(outsider);
        vm.expectRevert(ForcedTransferController.ForcedTransferController__Unauthorized.selector);
        controller.setEnabled(true);

        vm.prank(guardian);
        controller.setEnabled(true);
        vm.prank(guardian);
        controller.setEnabled(true); // no-op path

        vm.prank(outsider);
        vm.expectRevert(ForcedTransferController.ForcedTransferController__Unauthorized.selector);
        controller.setToken(tokenAddr);

        vm.expectRevert(ForcedTransferController.ForcedTransferController__InvalidAddress.selector);
        controller.setToken(address(0));

        controller.setToken(tokenAddr);
        assertEq(controller.token(), tokenAddr);

        vm.prank(outsider);
        vm.expectRevert(ForcedTransferController.ForcedTransferController__Unauthorized.selector);
        controller.setFreezeModule(address(freeze));

        vm.expectRevert(ForcedTransferController.ForcedTransferController__InvalidAddress.selector);
        controller.setFreezeModule(address(0));

        CovCtrlFreeze freeze2 = new CovCtrlFreeze(address(rm));
        freeze2.setFrozenTokens(alice, 70);
        controller.setFreezeModule(address(freeze2));

        (uint256 fb1, uint256 fa1) = controller.previewFrozenAfter(alice, 20, 100);
        assertEq(fb1, 70);
        assertEq(fa1, 70);

        (uint256 fb2, uint256 fa2) = controller.previewFrozenAfter(alice, 90, 100);
        assertEq(fb2, 70);
        assertEq(fa2, 10);
    }

    function testControllerPreForcedTransferGuardsAndHappyPath() public {
        controller.setToken(tokenAddr);

        vm.expectRevert(ForcedTransferController.ForcedTransferController__OnlyToken.selector);
        controller.preForcedTransfer(enforcer, alice, bob, 1, 100);

        vm.prank(tokenAddr);
        vm.expectRevert(ForcedTransferController.ForcedTransferController__Disabled.selector);
        controller.preForcedTransfer(enforcer, alice, bob, 1, 100);

        controller.setEnabled(true);

        vm.prank(tokenAddr);
        vm.expectRevert(ForcedTransferController.ForcedTransferController__InvalidFromTo.selector);
        controller.preForcedTransfer(enforcer, address(0), bob, 1, 100);

        vm.prank(tokenAddr);
        vm.expectRevert(ForcedTransferController.ForcedTransferController__InvalidFromTo.selector);
        controller.preForcedTransfer(enforcer, alice, alice, 1, 100);

        vm.prank(tokenAddr);
        vm.expectRevert(ForcedTransferController.ForcedTransferController__InvalidAmount.selector);
        controller.preForcedTransfer(enforcer, alice, bob, 0, 100);

        vm.prank(tokenAddr);
        vm.expectRevert(ForcedTransferController.ForcedTransferController__Unauthorized.selector);
        controller.preForcedTransfer(outsider, alice, bob, 1, 100);

        vm.prank(tokenAddr);
        vm.expectRevert(abi.encodeWithSelector(ForcedTransferController.ForcedTransferController__InsufficientBalance.selector, 5, 10));
        controller.preForcedTransfer(enforcer, alice, bob, 10, 5);

        freeze.setFrozenTokens(alice, 120);
        vm.prank(tokenAddr);
        (uint256 before1, uint256 after1) = controller.preForcedTransfer(enforcer, alice, bob, 10, 100);
        assertEq(before1, 120);
        assertEq(after1, 90);

        freeze.setFrozenTokens(alice, 20);
        vm.prank(tokenAddr);
        (uint256 before2, uint256 after2) = controller.preForcedTransfer(enforcer, alice, bob, 10, 100);
        assertEq(before2, 20);
        assertEq(after2, 20);
    }
}

contract FreezeManagerCoverageTest is Test {
    RoleManager internal rm;
    FreezeManager internal freeze;

    address internal enforcer = makeAddr("enforcer");
    address internal outsider = makeAddr("outsider");
    address internal tokenAddr = makeAddr("token");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        rm = new RoleManager(address(this));
        rm.grantRole(UAgriRoles.REGULATOR_ENFORCER_ROLE, enforcer);
        freeze = new FreezeManager(address(rm), address(0));
    }

    function testFreezeViewsAndAdminTokenConfig() public {
        assertEq(freeze.roleManager(), address(rm));
        assertEq(freeze.getFrozenTokens(alice), 0);
        assertEq(freeze.frozenOf(alice), 0);

        vm.expectRevert(FreezeManager.FreezeManager__BadInit.selector);
        freeze.initialize(address(rm), tokenAddr);

        vm.prank(outsider);
        vm.expectRevert(FreezeManager.FreezeManager__Unauthorized.selector);
        freeze.setToken(tokenAddr);

        vm.expectRevert(FreezeManager.FreezeManager__InvalidAddress.selector);
        freeze.setToken(address(0));

        freeze.setToken(tokenAddr);
        assertEq(freeze.token(), tokenAddr);
    }

    function testFreezeAdminAndTokenOnlyPaths() public {
        freeze.setToken(tokenAddr);

        vm.prank(outsider);
        vm.expectRevert(FreezeManager.FreezeManager__Unauthorized.selector);
        freeze.setFrozenTokens(alice, 1);

        vm.prank(enforcer);
        vm.expectRevert(FreezeManager.FreezeManager__InvalidAddress.selector);
        freeze.setFrozenTokens(address(0), 1);

        vm.prank(enforcer);
        freeze.setFrozenTokens(alice, 50);
        assertEq(freeze.getFrozenTokens(alice), 50);

        address[] memory accounts = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        accounts[0] = alice;
        accounts[1] = bob;
        amounts[0] = 1;

        vm.prank(enforcer);
        vm.expectRevert(FreezeManager.FreezeManager__LengthMismatch.selector);
        freeze.setFrozenTokensBatch(accounts, amounts);

        amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 2;
        accounts[1] = address(0);
        vm.prank(enforcer);
        vm.expectRevert(FreezeManager.FreezeManager__InvalidAddress.selector);
        freeze.setFrozenTokensBatch(accounts, amounts);

        accounts[1] = bob;
        vm.prank(enforcer);
        freeze.setFrozenTokensBatch(accounts, amounts);
        assertEq(freeze.getFrozenTokens(alice), 1);
        assertEq(freeze.getFrozenTokens(bob), 2);

        vm.prank(enforcer);
        vm.expectRevert(FreezeManager.FreezeManager__InvalidAddress.selector);
        freeze.increaseFrozen(address(0), 1);

        vm.prank(enforcer);
        freeze.increaseFrozen(alice, 9);
        assertEq(freeze.getFrozenTokens(alice), 10);

        vm.prank(enforcer);
        vm.expectRevert(FreezeManager.FreezeManager__InvalidAddress.selector);
        freeze.decreaseFrozen(address(0), 1);

        vm.prank(enforcer);
        freeze.decreaseFrozen(alice, 1000);
        assertEq(freeze.getFrozenTokens(alice), 0);

        vm.prank(outsider);
        vm.expectRevert(FreezeManager.FreezeManager__OnlyToken.selector);
        freeze.setFrozenTokensFromToken(alice, 1);

        vm.prank(tokenAddr);
        vm.expectRevert(FreezeManager.FreezeManager__InvalidAddress.selector);
        freeze.setFrozenTokensFromToken(address(0), 1);

        vm.prank(tokenAddr);
        freeze.setFrozenTokensFromToken(alice, 77);
        assertEq(freeze.getFrozenTokens(alice), 77);

        vm.prank(outsider);
        vm.expectRevert(FreezeManager.FreezeManager__OnlyToken.selector);
        freeze.setFrozenTokensBatchFromToken(accounts, amounts);

        uint256[] memory wrong = new uint256[](1);
        wrong[0] = 1;
        vm.prank(tokenAddr);
        vm.expectRevert(FreezeManager.FreezeManager__LengthMismatch.selector);
        freeze.setFrozenTokensBatchFromToken(accounts, wrong);

        accounts[1] = address(0);
        vm.prank(tokenAddr);
        vm.expectRevert(FreezeManager.FreezeManager__InvalidAddress.selector);
        freeze.setFrozenTokensBatchFromToken(accounts, amounts);

        accounts[1] = bob;
        vm.prank(tokenAddr);
        freeze.setFrozenTokensBatchFromToken(accounts, amounts);
        assertEq(freeze.getFrozenTokens(alice), 1);
        assertEq(freeze.getFrozenTokens(bob), 2);
    }
}

