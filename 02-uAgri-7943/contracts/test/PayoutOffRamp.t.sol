// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {YieldAccumulator} from "src/distribution/YieldAccumulator.sol";
import {IAgriTreasuryV1} from "src/interfaces/v1/IAgriTreasuryV1.sol";

import {UAgriTypes} from "src/interfaces/constants/UAgriTypes.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";
import {UAgriFlags} from "src/interfaces/constants/UAgriFlags.sol";
import {UAgriErrors} from "src/interfaces/constants/UAgriErrors.sol";

contract PayoutERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ALLOW");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "TO_ZERO");
        uint256 b = balanceOf[from];
        require(b >= amount, "BAL");
        unchecked {
            balanceOf[from] = b - amount;
            balanceOf[to] += amount;
        }
    }
}

contract PayoutTreasury is IAgriTreasuryV1 {
    address public settlementAsset;
    mapping(uint64 => uint256) public inflowByEpoch;

    constructor(address asset) {
        settlementAsset = asset;
    }

    function availableBalance() external view returns (uint256) {
        return PayoutERC20(settlementAsset).balanceOf(address(this));
    }

    function pay(address to, uint256 amount, bytes32 purpose) external {
        bool ok = PayoutERC20(settlementAsset).transfer(to, amount);
        require(ok, "TRANSFER_FAIL");
        emit Paid(to, amount, purpose);
    }

    function noteInflow(uint64 epoch, uint256 amount, bytes32 reportHash) external {
        inflowByEpoch[epoch] += amount;
        emit InflowNoted(epoch, amount, reportHash);
    }
}

contract PayoutCompliance {
    bool public allowed = true;

    function setAllowed(bool v) external {
        allowed = v;
    }

    function canTransact(address) external view returns (bool) {
        return allowed;
    }
}

contract PayoutDisaster {
    uint256 public flags;
    bool public restricted;
    bool public hardFrozen;

    function setState(uint256 flags_, bool restricted_, bool hardFrozen_) external {
        flags = flags_;
        restricted = restricted_;
        hardFrozen = hardFrozen_;
    }

    function campaignFlags(bytes32) external view returns (uint256) {
        return flags;
    }

    function isRestricted(bytes32) external view returns (bool) {
        return restricted;
    }

    function isHardFrozen(bytes32) external view returns (bool) {
        return hardFrozen;
    }
}

contract Payout1271Signer {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bool public valid = true;

    function setValid(bool v) external {
        valid = v;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return valid ? MAGIC : bytes4(0xffffffff);
    }
}

contract PayoutShareToken {
    address public roleManager;
    bytes32 public campaignId;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    address public compliance;
    address public disaster;
    address public treasuryAddr;

    UAgriTypes.ViewGasLimits internal _gas;

    constructor(address roleManager_, bytes32 campaignId_, address compliance_, address disaster_, address treasury_) {
        roleManager = roleManager_;
        campaignId = campaignId_;
        compliance = compliance_;
        disaster = disaster_;
        treasuryAddr = treasury_;
        _gas = UAgriTypes.ViewGasLimits({
            complianceGas: 200_000,
            disasterGas: 200_000,
            freezeGas: 200_000,
            custodyGas: 200_000,
            extraGas: 200_000
        });
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setTotalSupply(uint256 amount) external {
        totalSupply = amount;
    }

    function complianceModule() external view returns (address) {
        return compliance;
    }

    function disasterModule() external view returns (address) {
        return disaster;
    }

    function treasury() external view returns (address) {
        return treasuryAddr;
    }

    function viewGasLimits() external view returns (UAgriTypes.ViewGasLimits memory) {
        return _gas;
    }
}

contract PayoutOffRampTest is Test {
    RoleManager internal rm;
    PayoutERC20 internal usdc;
    PayoutTreasury internal treasury;
    PayoutCompliance internal compliance;
    PayoutDisaster internal disaster;
    PayoutShareToken internal share;
    YieldAccumulator internal yieldAcc;

    bytes32 internal campaignId = keccak256("payout-off-ramp");

    uint256 internal alicePk = 0xA11CE;
    address internal alice;
    address internal sink = makeAddr("fiat-sink");
    address internal notifier = makeAddr("reward-notifier");
    address internal payoutOperator = makeAddr("payout-operator");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        alice = vm.addr(alicePk);

        rm = new RoleManager(address(this));
        usdc = new PayoutERC20();
        treasury = new PayoutTreasury(address(usdc));
        compliance = new PayoutCompliance();
        disaster = new PayoutDisaster();

        share = new PayoutShareToken(
            address(rm),
            campaignId,
            address(compliance),
            address(disaster),
            address(treasury)
        );
        share.setTotalSupply(1_000_000);
        share.setBalance(alice, 600_000);

        yieldAcc = new YieldAccumulator(address(rm), address(share), address(usdc), false);

        rm.grantRole(UAgriRoles.REWARD_NOTIFIER_ROLE, notifier);
        rm.grantRole(UAgriRoles.PAYOUT_OPERATOR_ROLE, payoutOperator);

        _fundTreasury(200_000);
        vm.prank(notifier);
        yieldAcc.notifyReward(200_000, 1, keccak256("liquidation-1"));
        assertEq(yieldAcc.lastLiquidationId(), 1);
    }

    function testClaimToWithSig_movesUSDC_toSink_marksRef_storesLiquidationId() public {
        bytes32 ref = keccak256("payout-ref-1");
        bytes32 payoutRailHash = keccak256("rail-1");
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 maxAmount = 60_000;

        uint256 pendingBefore = yieldAcc.pending(alice);
        uint256 expected = pendingBefore < maxAmount ? pendingBefore : maxAmount;
        bytes memory sig = _signClaim(alicePk, alice, sink, maxAmount, deadline, ref, payoutRailHash);
        uint256 sinkBefore = usdc.balanceOf(sink);

        vm.prank(payoutOperator);
        uint256 paid = yieldAcc.claimToWithSig(
            alice,
            sink,
            maxAmount,
            deadline,
            ref,
            payoutRailHash,
            sig
        );

        assertEq(paid, expected);
        assertEq(usdc.balanceOf(sink), sinkBefore + expected);
        assertTrue(yieldAcc.usedPayoutRef(ref));

        _assertStoredPayout(ref, expected, payoutRailHash);
    }

    function testClaimToWithSig_revertsOnRefReplay() public {
        bytes32 ref = keccak256("payout-ref-replay");
        bytes32 payoutRailHash = keccak256("rail-replay");
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 maxAmount = 40_000;

        bytes memory sig = _signClaim(alicePk, alice, sink, maxAmount, deadline, ref, payoutRailHash);

        vm.prank(payoutOperator);
        yieldAcc.claimToWithSig(
            alice,
            sink,
            maxAmount,
            deadline,
            ref,
            payoutRailHash,
            sig
        );

        vm.prank(payoutOperator);
        vm.expectRevert(UAgriErrors.UAgri__Replay.selector);
        yieldAcc.claimToWithSig(
            alice,
            sink,
            maxAmount,
            deadline,
            ref,
            payoutRailHash,
            sig
        );
    }

    function testClaimToWithSig_revertsIfNotPayoutOperator() public {
        bytes32 ref = keccak256("payout-ref-auth");
        bytes32 payoutRailHash = keccak256("rail-auth");
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 maxAmount = 30_000;
        bytes memory sig = _signClaim(alicePk, alice, sink, maxAmount, deadline, ref, payoutRailHash);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        yieldAcc.claimToWithSig(
            alice,
            sink,
            maxAmount,
            deadline,
            ref,
            payoutRailHash,
            sig
        );
    }

    function testClaimToWithSig_revertsIfPausedClaims() public {
        bytes32 ref = keccak256("payout-ref-paused");
        bytes32 payoutRailHash = keccak256("rail-paused");
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 maxAmount = 20_000;
        bytes memory sig = _signClaim(alicePk, alice, sink, maxAmount, deadline, ref, payoutRailHash);

        disaster.setState(UAgriFlags.PAUSE_CLAIMS, false, false);

        vm.prank(payoutOperator);
        vm.expectRevert(UAgriErrors.UAgri__Paused.selector);
        yieldAcc.claimToWithSig(
            alice,
            sink,
            maxAmount,
            deadline,
            ref,
            payoutRailHash,
            sig
        );
    }

    function testConfirmPayout_setsReceiptOnce() public {
        bytes32 ref = keccak256("payout-ref-confirm");
        bytes32 payoutRailHash = keccak256("rail-confirm");
        bytes32 receiptHash = keccak256("receipt-1");
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 maxAmount = 25_000;
        bytes memory sig = _signClaim(alicePk, alice, sink, maxAmount, deadline, ref, payoutRailHash);

        vm.prank(payoutOperator);
        yieldAcc.claimToWithSig(
            alice,
            sink,
            maxAmount,
            deadline,
            ref,
            payoutRailHash,
            sig
        );

        vm.prank(payoutOperator);
        yieldAcc.confirmPayout(ref, receiptHash);

        (, , , , bytes32 storedReceipt, ) = yieldAcc.payoutByRef(ref);
        assertEq(storedReceipt, receiptHash);

        vm.prank(payoutOperator);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__PayoutAlreadyConfirmed.selector);
        yieldAcc.confirmPayout(ref, keccak256("receipt-2"));
    }

    function testPayoutTypedDataHelpers_domainAndStructHash() public view {
        bytes32 ds = yieldAcc.domainSeparator();
        assertTrue(ds != bytes32(0));

        bytes32 structHash = yieldAcc.hashPayoutClaimStruct(
            alice,
            sink,
            1,
            uint64(block.timestamp + 1 days),
            keccak256("ref"),
            keccak256("rail")
        );
        assertTrue(structHash != bytes32(0));
    }

    function testClaimToWithSig_revertsOnInvalidAddressAndDeadline() public {
        bytes32 payoutRailHash = keccak256("rail-invalid");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 refBadAddress = keccak256("ref-bad-address");
        bytes32 refExpired = keccak256("ref-expired");

        bytes memory sigBadAddress =
            _signClaim(alicePk, address(0), sink, 10_000, deadline, refBadAddress, payoutRailHash);

        vm.prank(payoutOperator);
        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        yieldAcc.claimToWithSig(
            address(0),
            sink,
            10_000,
            deadline,
            refBadAddress,
            payoutRailHash,
            sigBadAddress
        );

        vm.warp(block.timestamp + 100);
        uint64 expiredDeadline = uint64(block.timestamp - 1);
        bytes memory sigExpired =
            _signClaim(alicePk, alice, sink, 10_000, expiredDeadline, refExpired, payoutRailHash);

        vm.prank(payoutOperator);
        vm.expectRevert(UAgriErrors.UAgri__DeadlineExpired.selector);
        yieldAcc.claimToWithSig(
            alice,
            sink,
            10_000,
            expiredDeadline,
            refExpired,
            payoutRailHash,
            sigExpired
        );
    }

    function testClaimToWithSig_revertsIfRestrictedOrHardFrozen() public {
        bytes32 rail = keccak256("rail-state");
        uint64 deadline = uint64(block.timestamp + 1 days);

        bytes32 refRestricted = keccak256("ref-restricted");
        bytes memory sigRestricted =
            _signClaim(alicePk, alice, sink, 10_000, deadline, refRestricted, rail);
        disaster.setState(0, true, false);
        vm.prank(payoutOperator);
        vm.expectRevert(UAgriErrors.UAgri__Restricted.selector);
        yieldAcc.claimToWithSig(
            alice,
            sink,
            10_000,
            deadline,
            refRestricted,
            rail,
            sigRestricted
        );

        bytes32 refFrozen = keccak256("ref-frozen");
        bytes memory sigFrozen =
            _signClaim(alicePk, alice, sink, 10_000, deadline, refFrozen, rail);
        disaster.setState(0, false, true);
        vm.prank(payoutOperator);
        vm.expectRevert(UAgriErrors.UAgri__HardFrozen.selector);
        yieldAcc.claimToWithSig(
            alice,
            sink,
            10_000,
            deadline,
            refFrozen,
            rail,
            sigFrozen
        );
    }

    function testClaimToWithSig_contractSigner1271Path() public {
        Payout1271Signer signer = new Payout1271Signer();
        share.setBalance(address(signer), 100_000);
        share.setTotalSupply(1_100_000);

        bytes32 ref = keccak256("ref-1271");
        bytes32 rail = keccak256("rail-1271");
        uint64 deadline = uint64(block.timestamp + 1 days);

        vm.prank(payoutOperator);
        uint256 paid = yieldAcc.claimToWithSig(
            address(signer),
            sink,
            10_000,
            deadline,
            ref,
            rail,
            hex"01"
        );
        assertGt(paid, 0);
        assertTrue(yieldAcc.usedPayoutRef(ref));
    }

    function testClaimToWithSig_revertsWhenComplianceEnabledAndDenied() public {
        YieldAccumulator strictAcc = new YieldAccumulator(address(rm), address(share), address(usdc), true);
        _fundTreasury(50_000);
        vm.prank(notifier);
        strictAcc.notifyReward(50_000, 1, keccak256("strict-liq-1"));

        compliance.setAllowed(false);

        bytes32 ref = keccak256("ref-strict");
        bytes32 rail = keccak256("rail-strict");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signClaimFor(strictAcc, alicePk, alice, sink, 10_000, deadline, ref, rail);

        vm.prank(payoutOperator);
        vm.expectRevert(UAgriErrors.UAgri__ComplianceDenied.selector);
        strictAcc.claimToWithSig(
            alice,
            sink,
            10_000,
            deadline,
            ref,
            rail,
            sig
        );
    }

    function testConfirmPayout_rolePathsAndValidationErrors() public {
        bytes32 ref = keccak256("confirm-ref-missing");
        bytes32 receiptHash = keccak256("receipt-missing");
        address governance = makeAddr("governance");

        rm.grantRole(UAgriRoles.GOVERNANCE_ROLE, governance);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        yieldAcc.confirmPayout(ref, receiptHash);

        vm.prank(payoutOperator);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidReceiptHash.selector);
        yieldAcc.confirmPayout(ref, bytes32(0));

        vm.prank(governance);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__PayoutNotFound.selector);
        yieldAcc.confirmPayout(ref, receiptHash);

        vm.expectRevert(YieldAccumulator.YieldAccumulator__PayoutNotFound.selector);
        yieldAcc.confirmPayout(keccak256("confirm-ref-admin"), keccak256("receipt-admin"));
    }

    function _signClaim(
        uint256 signerPk,
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash
    ) internal returns (bytes memory) {
        bytes32 digest = yieldAcc.hashPayoutClaim(
            account,
            to,
            maxAmount,
            deadline,
            ref,
            payoutRailHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signClaimFor(
        YieldAccumulator acc,
        uint256 signerPk,
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash
    ) internal returns (bytes memory) {
        bytes32 digest = acc.hashPayoutClaim(
            account,
            to,
            maxAmount,
            deadline,
            ref,
            payoutRailHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fundTreasury(uint256 amount) internal {
        usdc.mint(address(treasury), amount);
    }

    function _assertStoredPayout(bytes32 ref, uint256 expectedAmount, bytes32 expectedRailHash) internal view {
        (
            address accountStored,
            address toStored,
            uint256 amountStored,
            bytes32 railHashStored,
            bytes32 receiptHashStored,
            uint256 liquidationIdAtRequest
        ) = yieldAcc.payoutByRef(ref);

        assertEq(accountStored, alice);
        assertEq(toStored, sink);
        assertEq(amountStored, expectedAmount);
        assertEq(railHashStored, expectedRailHash);
        assertEq(receiptHashStored, bytes32(0));
        assertEq(liquidationIdAtRequest, 1);
    }
}
