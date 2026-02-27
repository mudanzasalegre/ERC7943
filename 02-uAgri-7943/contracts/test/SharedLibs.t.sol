// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {PackedUint} from "src/_shared/PackedUint.sol";
import {ECDSA} from "src/_shared/ECDSA.sol";
import {EIP712} from "src/_shared/EIP712.sol";
import {SafeStaticCall} from "src/_shared/SafeStaticCall.sol";
import {SafeERC20} from "src/_shared/SafeERC20.sol";
import {TwoStepAdmin} from "src/_shared/TwoStepAdmin.sol";
import {ClonesLib} from "src/factory/ClonesLib.sol";

contract PackedUintHarness {
    function getAt(uint256 word, uint8 offset, uint8 bits) external pure returns (uint256) {
        return PackedUint.getAt(word, offset, bits);
    }

    function setAt(uint256 word, uint8 offset, uint8 bits, uint256 value) external pure returns (uint256) {
        return PackedUint.setAt(word, offset, bits, value);
    }

    function clearAt(uint256 word, uint8 offset, uint8 bits) external pure returns (uint256) {
        return PackedUint.clearAt(word, offset, bits);
    }

    function setBool(uint256 word, uint8 bit, bool value) external pure returns (uint256) {
        return PackedUint.setBool(word, bit, value);
    }

    function getBool(uint256 word, uint8 bit) external pure returns (bool) {
        return PackedUint.getBool(word, bit);
    }

    function setIntAt(uint256 word, uint8 offset, uint8 bits, int256 value) external pure returns (uint256) {
        return PackedUint.setIntAt(word, offset, bits, value);
    }

    function getIntAt(uint256 word, uint8 offset, uint8 bits) external pure returns (int256) {
        return PackedUint.getIntAt(word, offset, bits);
    }

    function addAt(uint256 word, uint8 offset, uint8 bits, uint256 delta) external pure returns (uint256) {
        return PackedUint.addAt(word, offset, bits, delta);
    }

    function subAt(uint256 word, uint8 offset, uint8 bits, uint256 delta) external pure returns (uint256) {
        return PackedUint.subAt(word, offset, bits, delta);
    }

    function maxValue(uint8 bits) external pure returns (uint256) {
        return PackedUint.maxValue(bits);
    }

    function maskAt(uint8 offset, uint8 bits) external pure returns (uint256) {
        return PackedUint.maskAt(offset, bits);
    }
}

contract ECDSAHarness {
    function recoverSig(bytes32 hash, bytes memory sig) external pure returns (address) {
        return ECDSA.recover(hash, sig);
    }

    function recoverVRS(bytes32 hash, uint8 v, bytes32 r, bytes32 s) external pure returns (address) {
        return ECDSA.recover(hash, v, r, s);
    }

    function recoverRVS(bytes32 hash, bytes32 r, bytes32 vs) external pure returns (address) {
        return ECDSA.recover(hash, r, vs);
    }

    function ethHash32(bytes32 h) external pure returns (bytes32) {
        return ECDSA.toEthSignedMessageHash(h);
    }

    function ethHashBytes(bytes memory m) external pure returns (bytes32) {
        return ECDSA.toEthSignedMessageHash(m);
    }
}

contract EIP712Harness is EIP712 {
    constructor(string memory n, string memory v) EIP712(n, v) {}

    function hashTyped(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    function recoverTyped(bytes32 structHash, bytes memory sig) external view returns (address) {
        return _recoverTypedDataSigner(structHash, sig);
    }
}

contract StaticCallTarget {
    function retBool() external pure returns (bool) {
        return true;
    }

    function retUint() external pure returns (uint256) {
        return 123;
    }

    function retBytes32() external pure returns (bytes32) {
        return keccak256("bytes32");
    }

    function retBoolUint8() external pure returns (bool, uint8) {
        return (true, 9);
    }

    function retBoolBytes32() external pure returns (bool, bytes32) {
        return (true, keccak256("pair"));
    }

    function revertAlways() external pure {
        revert("x");
    }

    function malformed() external pure {
        // Intentionally returns empty data to trigger strict decoder failure paths.
    }
}

contract SafeStaticCallHarness {
    function raw(address target, uint256 gasStipend, bytes memory callData, uint256 maxRetBytes)
        external
        view
        returns (bool ok, bytes memory ret)
    {
        return SafeStaticCall.staticcallRaw(target, gasStipend, callData, maxRetBytes);
    }

    function callBool(address target, bytes memory callData) external view returns (bool ok, bool value) {
        return SafeStaticCall.tryStaticCallBool(target, 0, callData, 0);
    }

    function callUint(address target, bytes memory callData) external view returns (bool ok, uint256 value) {
        return SafeStaticCall.tryStaticCallUint256(target, 0, callData, 0);
    }

    function callBytes32(address target, bytes memory callData) external view returns (bool ok, bytes32 value) {
        return SafeStaticCall.tryStaticCallBytes32(target, 0, callData, 0);
    }

    function callBoolUint8(address target, bytes memory callData) external view returns (bool ok, bool a, uint8 b) {
        return SafeStaticCall.tryStaticCallBoolUint8(target, 0, callData, 0);
    }

    function callBoolBytes32(address target, bytes memory callData)
        external
        view
        returns (bool ok, bool a, bytes32 b)
    {
        return SafeStaticCall.tryStaticCallBoolBytes32(target, 0, callData, 0);
    }

    function failClosedBool(address target, bytes memory callData) external view returns (bool) {
        return SafeStaticCall.staticCallBoolFailClosed(target, callData);
    }

    function failClosedUint(address target, bytes memory callData) external view returns (uint256) {
        return SafeStaticCall.staticCallUint256FailClosed(target, callData);
    }
}

contract SafeERC20Harness {
    function safeTransfer(address token, address to, uint256 amount) external {
        SafeERC20.safeTransfer(token, to, amount);
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) external {
        SafeERC20.safeTransferFrom(token, from, to, amount);
    }

    function safeApprove(address token, address spender, uint256 amount) external {
        SafeERC20.safeApprove(token, spender, amount);
    }

    function forceApprove(address token, address spender, uint256 amount) external {
        SafeERC20.forceApprove(token, spender, amount);
    }

    function safeIncreaseAllowance(address token, address spender, uint256 increment) external {
        SafeERC20.safeIncreaseAllowance(token, spender, increment);
    }

    function safeDecreaseAllowance(address token, address spender, uint256 decrement) external {
        SafeERC20.safeDecreaseAllowance(token, spender, decrement);
    }

    function safePermit(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        SafeERC20.safePermit(token, owner, spender, value, deadline, v, r, s);
    }
}

contract TokenTrue {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ALLOW");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external virtual returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external virtual {
        allowance[owner][spender] = value;
    }
}

contract TokenNoReturn {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ALLOW");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }
}

contract TokenFalse is TokenTrue {
    function transfer(address, uint256) external pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure override returns (bool) {
        return false;
    }
}

contract TokenRevert is TokenTrue {
    function transfer(address, uint256) external pure override returns (bool) {
        revert("revert");
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        revert("revert");
    }

    function approve(address, uint256) external pure override returns (bool) {
        revert("revert");
    }
}

contract TokenApproveZeroFirst is TokenTrue {
    function approve(address spender, uint256 amount) external override returns (bool) {
        uint256 cur = allowance[msg.sender][spender];
        if (cur != 0 && amount != 0) {
            return false;
        }
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract TokenPermitMaybeRevert is TokenTrue {
    bool public failPermit;

    function setFailPermit(bool v) external {
        failPermit = v;
    }

    function permit(address owner, address spender, uint256 value, uint256 d, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        owner;
        spender;
        value;
        d;
        v;
        r;
        s;
        if (failPermit) {
            revert("permit-fail");
        }
        allowance[owner][spender] = value;
    }
}

contract TwoStepAdminHarness is TwoStepAdmin {
    constructor(address admin_) TwoStepAdmin(admin_) {}

    function guarded() external view returns (bool) {
        _requireAdmin();
        return true;
    }
}

contract CloneImpl {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }

    function ping() external pure returns (uint256) {
        return 7;
    }
}

contract ClonesHarness {
    function clone(address implementation) external returns (address) {
        return ClonesLib.clone(implementation);
    }

    function cloneDeterministic(address implementation, bytes32 salt) external returns (address) {
        return ClonesLib.cloneDeterministic(implementation, salt);
    }

    function predict(address implementation, bytes32 salt, address deployer) external pure returns (address) {
        return ClonesLib.predictDeterministicAddress(implementation, salt, deployer);
    }

    function predictSelf(address implementation, bytes32 salt) external view returns (address) {
        return ClonesLib.predictDeterministicAddress(implementation, salt);
    }
}

contract PackedUintTest is Test {
    PackedUintHarness internal h;

    function setUp() public {
        h = new PackedUintHarness();
    }

    function testPackedUintSetGetBoolAndInt() public view {
        uint256 word = 0;

        word = h.setAt(word, 8, 8, 0xAB);
        assertEq(h.getAt(word, 8, 8), 0xAB);

        word = h.setBool(word, 1, true);
        assertTrue(h.getBool(word, 1));

        word = h.setIntAt(word, 16, 8, -5);
        assertEq(h.getIntAt(word, 16, 8), -5);

        word = h.clearAt(word, 8, 8);
        assertEq(h.getAt(word, 8, 8), 0);
    }

    function testPackedUintArithmeticAndMasks() public view {
        uint256 word = h.setAt(0, 0, 16, 10);
        word = h.addAt(word, 0, 16, 5);
        assertEq(h.getAt(word, 0, 16), 15);

        word = h.subAt(word, 0, 16, 3);
        assertEq(h.getAt(word, 0, 16), 12);

        assertEq(h.maxValue(8), 255);
        assertEq(h.maskAt(8, 8), uint256(0xFF) << 8);
    }

    function testPackedUintReverts() public {
        vm.expectRevert();
        h.setAt(0, 250, 10, 1);

        vm.expectRevert();
        h.setAt(0, 0, 8, 256);

        vm.expectRevert();
        h.setIntAt(0, 0, 8, 200);

        vm.expectRevert();
        h.subAt(0, 0, 8, 1);
    }
}

contract CryptoAndStaticCallTest is Test {
    ECDSAHarness internal ecdsa;
    EIP712Harness internal eip;
    SafeStaticCallHarness internal sh;
    StaticCallTarget internal target;

    function setUp() public {
        ecdsa = new ECDSAHarness();
        eip = new EIP712Harness("uAgri", "1");
        sh = new SafeStaticCallHarness();
        target = new StaticCallTarget();
    }

    function testECDSARecover65And64() public view {
        uint256 pk = 0xA11CE;
        address signer = vm.addr(pk);
        bytes32 digest = keccak256("digest");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig65 = abi.encodePacked(r, s, v);

        assertEq(ecdsa.recoverSig(digest, sig65), signer);

        bytes32 vs = bytes32((uint256(v - 27) << 255) | uint256(s));
        assertEq(ecdsa.recoverRVS(digest, r, vs), signer);
    }

    function testECDSAErrorPathsAndHashes() public {
        bytes32 digest = keccak256("digest-2");

        vm.expectRevert();
        ecdsa.recoverSig(digest, new bytes(63));

        vm.expectRevert();
        ecdsa.recoverVRS(digest, 29, bytes32(uint256(1)), bytes32(uint256(1)));

        vm.expectRevert();
        ecdsa.recoverVRS(digest, 27, bytes32(uint256(1)), bytes32(type(uint256).max));

        vm.expectRevert();
        ecdsa.recoverVRS(digest, 27, bytes32(0), bytes32(uint256(1)));

        assertTrue(ecdsa.ethHash32(digest) != bytes32(0));
        assertTrue(ecdsa.ethHashBytes(bytes("hello")) != bytes32(0));
    }

    function testEIP712HashAndRecover() public view {
        uint256 pk = 0xB0B;
        address signer = vm.addr(pk);

        bytes32 structHash = keccak256("struct");
        bytes32 digest = eip.hashTyped(structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertEq(eip.recoverTyped(structHash, sig), signer);
        assertTrue(eip.domainSeparatorV4() != bytes32(0));
    }

    function testSafeStaticCallWrappers() public view {
        (bool okB, bool vb) = sh.callBool(address(target), abi.encodeWithSelector(target.retBool.selector));
        assertTrue(okB);
        assertTrue(vb);

        (bool okU, uint256 vu) = sh.callUint(address(target), abi.encodeWithSelector(target.retUint.selector));
        assertTrue(okU);
        assertEq(vu, 123);

        (bool ok32, bytes32 v32) = sh.callBytes32(address(target), abi.encodeWithSelector(target.retBytes32.selector));
        assertTrue(ok32);
        assertEq(v32, keccak256("bytes32"));

        (bool okPair, bool a, uint8 b) = sh.callBoolUint8(address(target), abi.encodeWithSelector(target.retBoolUint8.selector));
        assertTrue(okPair);
        assertTrue(a);
        assertEq(b, 9);

        (bool okPair32, bool c, bytes32 d) =
            sh.callBoolBytes32(address(target), abi.encodeWithSelector(target.retBoolBytes32.selector));
        assertTrue(okPair32);
        assertTrue(c);
        assertEq(d, keccak256("pair"));
    }

    function testSafeStaticCallFailurePaths() public view {
        (bool okNoCode, bytes memory retNoCode) = sh.raw(address(0xBEEF), 0, "", 0);
        assertFalse(okNoCode);
        assertEq(retNoCode.length, 0);

        (bool okRev, bool vRev) = sh.callBool(address(target), abi.encodeWithSelector(target.revertAlways.selector));
        assertFalse(okRev);
        assertFalse(vRev);

        (bool okMalformed, bool vMalformed) = sh.callBool(address(target), abi.encodeWithSelector(target.malformed.selector));
        assertFalse(okMalformed);
        assertFalse(vMalformed);

        assertFalse(sh.failClosedBool(address(target), abi.encodeWithSelector(target.revertAlways.selector)));
        assertEq(sh.failClosedUint(address(target), abi.encodeWithSelector(target.revertAlways.selector)), 0);
    }
}

contract SafeERC20AndAdminTest is Test {
    SafeERC20Harness internal h;

    TokenTrue internal tTrue;
    TokenNoReturn internal tNoRet;
    TokenFalse internal tFalse;
    TokenRevert internal tRevert;
    TokenApproveZeroFirst internal tZeroFirst;
    TokenPermitMaybeRevert internal tPermit;

    TwoStepAdminHarness internal admin;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        h = new SafeERC20Harness();
        tTrue = new TokenTrue();
        tNoRet = new TokenNoReturn();
        tFalse = new TokenFalse();
        tRevert = new TokenRevert();
        tZeroFirst = new TokenApproveZeroFirst();
        tPermit = new TokenPermitMaybeRevert();

        admin = new TwoStepAdminHarness(address(this));
    }

    function testSafeERC20SuccessPaths() public {
        tTrue.mint(address(h), 1_000);
        h.safeTransfer(address(tTrue), alice, 100);
        assertEq(tTrue.balanceOf(alice), 100);

        tNoRet.mint(address(h), 500);
        h.safeTransfer(address(tNoRet), alice, 50);
        assertEq(tNoRet.balanceOf(alice), 50);

        tTrue.mint(alice, 300);
        vm.prank(alice);
        tTrue.approve(address(h), 200);
        h.safeTransferFrom(address(tTrue), alice, bob, 150);
        assertEq(tTrue.balanceOf(bob), 150);

        h.safeApprove(address(tTrue), bob, 10);
        h.safeIncreaseAllowance(address(tTrue), bob, 7);
        assertEq(tTrue.allowance(address(h), bob), 17);
        h.safeDecreaseAllowance(address(tTrue), bob, 10);
        assertEq(tTrue.allowance(address(h), bob), 7);

        h.forceApprove(address(tZeroFirst), bob, 5);
        h.forceApprove(address(tZeroFirst), bob, 12);
        assertEq(tZeroFirst.allowance(address(h), bob), 12);

        h.safePermit(address(tPermit), alice, bob, 99, block.timestamp + 1 days, 27, bytes32(0), bytes32(0));
        assertEq(tPermit.allowance(alice, bob), 99);
    }

    function testSafeERC20FailurePaths() public {
        vm.expectRevert();
        h.safeTransfer(address(tFalse), alice, 1);

        vm.expectRevert();
        h.safeTransfer(address(tRevert), alice, 1);

        vm.expectRevert();
        h.safeApprove(address(tFalse), bob, 1);

        vm.expectRevert();
        h.safeTransfer(address(0), alice, 1);

        tPermit.setFailPermit(true);
        vm.expectRevert();
        h.safePermit(address(tPermit), alice, bob, 1, block.timestamp + 1 days, 27, bytes32(0), bytes32(0));
    }

    function testTwoStepAdminFlow() public {
        assertTrue(admin.guarded());

        admin.transferAdmin(alice);
        assertEq(admin.pendingAdmin(), alice);

        vm.prank(bob);
        vm.expectRevert();
        admin.acceptAdmin();

        vm.prank(alice);
        admin.acceptAdmin();
        assertEq(admin.admin(), alice);

        vm.prank(alice);
        admin.renounceAdmin();
        assertEq(admin.admin(), address(0));

        vm.expectRevert();
        admin.acceptAdmin();
    }
}

contract ClonesLibTest is Test {
    ClonesHarness internal h;
    CloneImpl internal impl;

    function setUp() public {
        h = new ClonesHarness();
        impl = new CloneImpl();
    }

    function testCloneAndDeterministicPrediction() public {
        address c1 = h.clone(address(impl));
        CloneImpl(c1).setValue(11);
        assertEq(CloneImpl(c1).value(), 11);

        bytes32 salt = keccak256("clone-salt");
        address predicted = h.predict(address(impl), salt, address(h));
        assertEq(h.predictSelf(address(impl), salt), predicted);

        address c2 = h.cloneDeterministic(address(impl), salt);
        assertEq(c2, predicted);
        assertEq(CloneImpl(c2).ping(), 7);

        vm.expectRevert();
        h.cloneDeterministic(address(impl), salt);
    }

    function testCloneInvalidImplementationReverts() public {
        vm.expectRevert();
        h.clone(address(0));

        vm.expectRevert();
        h.cloneDeterministic(address(0), keccak256("x"));
    }
}
