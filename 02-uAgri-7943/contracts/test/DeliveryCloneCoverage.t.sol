// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {DeliveryModule} from "src/extensions/delivery/DeliveryModule.sol";
import {ClonesLib} from "src/factory/ClonesLib.sol";

contract CovDeliveryCloneHarness {
    function clone(address implementation) external returns (address) {
        return ClonesLib.clone(implementation);
    }
}

contract CovDeliveryDummyToken {}

contract DeliveryCloneCoverageTest is Test {
    RoleManager internal rm;
    DeliveryModule internal impl;
    DeliveryModule internal clone;

    CovDeliveryDummyToken internal token0;
    CovDeliveryDummyToken internal token1;

    address internal outsider = makeAddr("outsider");

    function setUp() public {
        rm = new RoleManager(address(this));
        token0 = new CovDeliveryDummyToken();
        token1 = new CovDeliveryDummyToken();

        impl = new DeliveryModule(address(rm), address(token0));

        CovDeliveryCloneHarness h = new CovDeliveryCloneHarness();
        clone = DeliveryModule(h.clone(address(impl)));
        clone.initialize(address(rm), address(token0));
    }

    function testCloneInitializeGuardAndAdminSetters() public {
        vm.expectRevert(DeliveryModule.Delivery__AlreadyInitialized.selector);
        clone.initialize(address(rm), address(token0));

        vm.prank(outsider);
        vm.expectRevert(DeliveryModule.Delivery__Unauthorized.selector);
        clone.setToken(address(token1));

        vm.prank(outsider);
        vm.expectRevert(DeliveryModule.Delivery__Unauthorized.selector);
        clone.setRoleManager(address(rm));

        clone.setToken(address(token1));
        assertEq(address(clone.token()), address(token1));

        vm.expectRevert(DeliveryModule.Delivery__InvalidAddress.selector);
        clone.setRoleManager(address(0));

        RoleManager rm2 = new RoleManager(address(this));
        clone.setRoleManager(address(rm2));
        assertEq(address(clone.roleManager()), address(rm2));
    }
}

