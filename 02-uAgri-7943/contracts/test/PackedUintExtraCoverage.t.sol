// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PackedUint} from "src/_shared/PackedUint.sol";

contract PackedUintExtraHarness {
    function makeField(uint8 offset, uint8 bits) external pure returns (uint8 outOffset, uint8 outBits) {
        PackedUint.Field memory f = PackedUint.field(offset, bits);
        return (f.offset, f.bits);
    }

    function getByField(uint256 word, uint8 offset, uint8 bits) external pure returns (uint256) {
        PackedUint.Field memory f = PackedUint.field(offset, bits);
        return PackedUint.get(word, f);
    }

    function setByField(uint256 word, uint8 offset, uint8 bits, uint256 value) external pure returns (uint256) {
        PackedUint.Field memory f = PackedUint.field(offset, bits);
        return PackedUint.set(word, f, value);
    }

    function clearByField(uint256 word, uint8 offset, uint8 bits) external pure returns (uint256) {
        PackedUint.Field memory f = PackedUint.field(offset, bits);
        return PackedUint.clear(word, f);
    }

    function getIntByField(uint256 word, uint8 offset, uint8 bits) external pure returns (int256) {
        PackedUint.Field memory f = PackedUint.field(offset, bits);
        return PackedUint.getInt(word, f);
    }

    function setIntByField(uint256 word, uint8 offset, uint8 bits, int256 value) external pure returns (uint256) {
        PackedUint.Field memory f = PackedUint.field(offset, bits);
        return PackedUint.setInt(word, f, value);
    }

    function addByField(uint256 word, uint8 offset, uint8 bits, uint256 delta) external pure returns (uint256) {
        PackedUint.Field memory f = PackedUint.field(offset, bits);
        return PackedUint.add(word, f, delta);
    }

    function subByField(uint256 word, uint8 offset, uint8 bits, uint256 delta) external pure returns (uint256) {
        PackedUint.Field memory f = PackedUint.field(offset, bits);
        return PackedUint.sub(word, f, delta);
    }

    function getIntAt(uint256 word, uint8 offset, uint8 bits) external pure returns (int256) {
        return PackedUint.getIntAt(word, offset, bits);
    }
}

contract PackedUintExtraCoverageTest is Test {
    PackedUintExtraHarness internal h;

    function setUp() public {
        h = new PackedUintExtraHarness();
    }

    function testFieldWrappersAndBit255SignedPaths() public view {
        (uint8 off, uint8 bits) = h.makeField(0, 255);
        assertEq(off, 0);
        assertEq(bits, 255);

        uint256 word = type(uint256).max - 123;
        uint256 max255 = type(uint256).max >> 1;
        assertEq(h.getByField(word, 0, 255), max255 - 123);
        assertEq(h.setByField(0, 0, 255, max255), max255);
        assertEq(h.clearByField(word, 0, 255), 1 << 255);

        uint256 packedNegTwo = h.setIntByField(0, 0, 255, -2);
        assertEq(h.getIntAt(packedNegTwo, 0, 255), -2);
        assertEq(h.getIntByField(packedNegTwo, 0, 255), -2);

        uint256 packedPos = h.setByField(0, 8, 8, 5);
        assertEq(h.getIntAt(packedPos, 8, 8), 5);

        uint256 w2 = h.setByField(0, 16, 8, 10);
        w2 = h.addByField(w2, 16, 8, 5);
        assertEq(h.getByField(w2, 16, 8), 15);
        w2 = h.subByField(w2, 16, 8, 3);
        assertEq(h.getByField(w2, 16, 8), 12);
    }

    function testInvalidFieldForMaxOffsetReverts() public {
        vm.expectRevert();
        h.makeField(2, 255);
    }

    function testBit255SignedBoundaryPath() public view {
        uint256 raw = type(uint256).max - 7;
        uint256 max255 = type(uint256).max >> 1;

        assertEq(h.getByField(raw, 0, 255), max255 - 7);
        assertEq(h.setByField(0, 0, 255, max255), max255);
        assertEq(h.clearByField(raw, 0, 255), 1 << 255);

        assertEq(h.getIntAt(type(uint256).max, 0, 255), -1);
        assertEq(h.setIntByField(0, 0, 255, -1), max255);
    }

    function testZeroBitsReverts() public {
        vm.expectRevert();
        h.makeField(0, 0);
    }
}
