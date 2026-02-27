// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {InsurancePool} from "src/disaster/InsurancePool.sol";

import {IAgriDisasterAdminV1} from "src/interfaces/v1/IAgriDisasterAdminV1.sol";

import {UAgriErrors} from "src/interfaces/constants/UAgriErrors.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";

contract CovInsuranceERC20 {
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 d) {
        decimals = d;
    }

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

contract CovInsuranceSnapshot {
    bytes32 public campaignId;
    bool public failTotalSupply;
    bool public failBalanceAt;

    mapping(uint64 => uint256) public totalSupplyAt;
    mapping(address => mapping(uint64 => uint256)) public balanceAt;

    constructor(bytes32 cid) {
        campaignId = cid;
    }

    function setCampaignId(bytes32 cid) external {
        campaignId = cid;
    }

    function setFailMode(bool failTs, bool failBal) external {
        failTotalSupply = failTs;
        failBalanceAt = failBal;
    }

    function setTotalSupplyAt(uint64 epoch, uint256 value) external {
        totalSupplyAt[epoch] = value;
    }

    function setBalanceAt(address account, uint64 epoch, uint256 value) external {
        balanceAt[account][epoch] = value;
    }

    function totalSupplyAtEpoch(uint64 epoch) external view returns (uint256) {
        if (failTotalSupply) revert("TS_FAIL");
        return totalSupplyAt[epoch];
    }

    function balanceOfAtEpoch(address account, uint64 epoch) external view returns (uint256) {
        if (failBalanceAt) revert("BAL_FAIL");
        return balanceAt[account][epoch];
    }
}

contract CovInsuranceDisaster is IAgriDisasterAdminV1 {
    DisasterState internal _state;

    function setConfirmed(bool confirmed) external {
        _state.confirmed = confirmed;
    }

    function setFlags(uint256 flags) external {
        _state.flags = flags;
    }

    function getDisaster(bytes32) external view returns (DisasterState memory) {
        return _state;
    }

    function campaignFlags(bytes32) external view returns (uint256 flags) {
        return _state.flags;
    }

    function isRestricted(bytes32) external view returns (bool) {
        return (_state.flags >> 255) != 0;
    }

    function isHardFrozen(bytes32) external view returns (bool) {
        return ((_state.flags >> 254) & 1) == 1;
    }

    function declareDisaster(bytes32, bytes32, uint8, bytes32, uint64) external {}

    function confirmDisaster(bytes32, uint256, uint8) external {
        _state.confirmed = true;
    }

    function clearDisaster(bytes32) external {
        _state.confirmed = false;
        _state.flags = 0;
    }
}

contract InsurancePoolCoverageTest is Test {
    RoleManager internal rm;
    InsurancePool internal pool;

    CovInsuranceERC20 internal payout;
    CovInsuranceSnapshot internal snapshot;
    CovInsuranceDisaster internal disaster;

    bytes32 internal campaignId = keccak256("ins-campaign");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal guardian = makeAddr("guardian");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        rm = new RoleManager(address(this));
        rm.grantRole(UAgriRoles.GUARDIAN_ROLE, guardian);

        payout = new CovInsuranceERC20(6);
        snapshot = new CovInsuranceSnapshot(campaignId);
        disaster = new CovInsuranceDisaster();
        disaster.setConfirmed(true);

        pool = new InsurancePool(address(rm), campaignId, address(payout), address(snapshot), address(disaster));
    }

    function testNotifyGuardsAndInitGuard() public {
        vm.expectRevert(InsurancePool.InsurancePool__AlreadyInitialized.selector);
        pool.initialize(address(rm), campaignId, address(payout), address(snapshot), address(disaster));

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        pool.notifyCompensation(1, 1, keccak256("r"));

        disaster.setConfirmed(false);
        vm.expectRevert(abi.encodeWithSelector(InsurancePool.InsurancePool__DisasterNotConfirmed.selector, campaignId));
        pool.notifyCompensation(1, 1, keccak256("r"));
        disaster.setConfirmed(true);

        vm.expectRevert(InsurancePool.InsurancePool__AmountZero.selector);
        pool.notifyCompensation(0, 1, keccak256("r"));

        vm.expectRevert(InsurancePool.InsurancePool__ReasonHashRequired.selector);
        pool.notifyCompensation(1, 1, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(InsurancePool.InsurancePool__SnapshotTotalSupplyZero.selector, uint64(1)));
        pool.notifyCompensation(1, 1, keccak256("r1"));

        snapshot.setTotalSupplyAt(1, 1000);
        vm.expectRevert(abi.encodeWithSelector(InsurancePool.InsurancePool__Underfunded.selector, 10, 0));
        pool.notifyCompensation(10, 1, keccak256("r1"));

        _fundPool(20);
        pool.notifyCompensation(10, 1, keccak256("r1"));

        vm.expectRevert(abi.encodeWithSelector(InsurancePool.InsurancePool__ReasonAlreadyUsed.selector, keccak256("r1")));
        pool.notifyCompensation(5, 2, keccak256("r1"));

        vm.expectRevert(abi.encodeWithSelector(InsurancePool.InsurancePool__EpochNotIncreasing.selector, uint64(1), uint64(1)));
        pool.notifyCompensation(5, 1, keccak256("r2"));

        vm.etch(address(snapshot), hex"");
        vm.expectRevert(InsurancePool.InsurancePool__InvalidSnapshotModule.selector);
        pool.notifyCompensation(5, 2, keccak256("r3"));
    }

    function testClaimPreviewAdminAndSweepPaths() public {
        _seedRound(1, 500, 1000, keccak256("reason-1"));
        _seedRound(2, 400, 1000, keccak256("reason-2"));
        snapshot.setBalanceAt(alice, 1, 200); // 100
        snapshot.setBalanceAt(alice, 2, 300); // 120
        snapshot.setBalanceAt(bob, 1, 800);
        snapshot.setBalanceAt(bob, 2, 700);

        (uint256 amount0, uint64 epoch0, bytes32 reason0) = pool.lastCompensation();
        assertEq(amount0, 400);
        assertEq(epoch0, 2);
        assertEq(reason0, keccak256("reason-2"));

        (uint256 totalAll, uint64 fromAll, uint64 toAll) = pool.previewClaim(alice);
        assertEq(totalAll, 220);
        assertEq(fromAll, 1);
        assertEq(toAll, 2);

        (uint256 totalPartial, uint64 fromPartial, uint64 toPartial) = pool.previewClaimUpTo(alice, 1);
        assertEq(totalPartial, 100);
        assertEq(fromPartial, 1);
        assertEq(toPartial, 1);

        vm.prank(alice);
        uint256 paid1 = pool.claimCompensationUpTo(1);
        assertEq(paid1, 100);
        assertEq(pool.lastClaimedEpoch(alice), 1);

        vm.prank(guardian);
        pool.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(InsurancePool.InsurancePool__Paused.selector);
        pool.claimCompensation();

        vm.prank(guardian);
        pool.setPaused(false);

        snapshot.setFailMode(false, true);
        vm.prank(alice);
        uint256 stopped = pool.claimCompensation();
        assertEq(stopped, 0);
        assertEq(pool.lastClaimedEpoch(alice), 1);

        snapshot.setFailMode(false, false);
        vm.prank(alice);
        uint256 paid2 = pool.claimCompensation();
        assertEq(paid2, 120);
        assertEq(pool.lastClaimedEpoch(alice), 2);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        pool.setPaused(true);

        payout.mint(address(pool), 50);
        assertEq(pool.withdrawableExcess(), 50);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        pool.withdrawExcess(bob, 1);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        pool.withdrawExcess(address(0), 1);

        vm.expectRevert(abi.encodeWithSelector(InsurancePool.InsurancePool__Underfunded.selector, 51, 50));
        pool.withdrawExcess(bob, 51);

        pool.withdrawExcess(bob, 20);
        assertEq(payout.balanceOf(bob), 20);

        InsurancePool.Round memory r1Before = pool.roundOf(1);
        assertEq(r1Before.remaining, 400);

        pool.sweepDust(999, bob); // non-existent round
        pool.sweepDust(1, bob);
        assertEq(payout.balanceOf(bob), 420);
        pool.sweepDust(1, bob); // dust already zero

        CovInsuranceERC20 pendingToken = new CovInsuranceERC20(6);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsurancePool.InsurancePool__Underfunded.selector, pool.totalRemaining(), payout.balanceOf(address(pool))
            )
        );
        pool.setPayoutToken(address(pendingToken));

        pool.sweepDust(2, bob);
        assertEq(pool.totalRemaining(), 0);

        CovInsuranceERC20 newPayout = new CovInsuranceERC20(18);
        pool.setPayoutToken(address(newPayout));
        assertEq(pool.payoutToken(), address(newPayout));

        CovInsuranceSnapshot snapshot2 = new CovInsuranceSnapshot(campaignId);
        pool.setSnapshotModule(address(snapshot2));
        assertEq(pool.snapshotModule(), address(snapshot2));

        CovInsuranceDisaster disaster2 = new CovInsuranceDisaster();
        pool.setDisasterModule(address(disaster2));
        assertEq(pool.disasterModule(), address(disaster2));
    }

    function testViewsAndSetterGuards() public {
        (uint256 amount, uint64 epoch, bytes32 reason) = pool.lastCompensation();
        assertEq(amount, 0);
        assertEq(epoch, 0);
        assertEq(reason, bytes32(0));

        (uint256 claimable, uint64 fromEpoch, uint64 toEpoch) = pool.previewClaim(alice);
        assertEq(claimable, 0);
        assertEq(fromEpoch, 0);
        assertEq(toEpoch, 0);

        assertEq(pool.withdrawableExcess(), 0);

        CovInsuranceSnapshot wrongSnapshot = new CovInsuranceSnapshot(keccak256("wrong"));
        vm.expectRevert(InsurancePool.InsurancePool__InvalidCampaignId.selector);
        pool.setSnapshotModule(address(wrongSnapshot));

        vm.expectRevert(InsurancePool.InsurancePool__InvalidSnapshotModule.selector);
        pool.setSnapshotModule(address(0));

        vm.expectRevert(InsurancePool.InsurancePool__InvalidDisasterModule.selector);
        pool.setDisasterModule(address(0));

        vm.expectRevert(InsurancePool.InsurancePool__InvalidPayoutToken.selector);
        pool.setPayoutToken(address(0));

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        pool.sweepDust(1, alice);

        _seedRound(1, 200, 1000, keccak256("reason-x"));
        vm.etch(address(snapshot), hex"");
        vm.prank(alice);
        uint256 paid = pool.claimCompensation();
        assertEq(paid, 0);
    }

    function _fundPool(uint256 amount) internal {
        payout.mint(address(this), amount);
        payout.approve(address(pool), amount);
        pool.fund(amount);
    }

    function _seedRound(uint64 epoch, uint256 amount, uint256 ts, bytes32 reasonHash) internal {
        snapshot.setTotalSupplyAt(epoch, ts);
        _fundPool(amount);
        pool.notifyCompensation(amount, epoch, reasonHash);
    }
}
