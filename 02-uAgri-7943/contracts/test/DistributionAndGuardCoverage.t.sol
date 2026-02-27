// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {SnapshotModule} from "src/distribution/SnapshotModule.sol";
import {YieldAccumulator} from "src/distribution/YieldAccumulator.sol";
import {ReentrancyGuard} from "src/_shared/ReentrancyGuard.sol";
import {IAgriTreasuryV1} from "src/interfaces/v1/IAgriTreasuryV1.sol";

import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";
import {UAgriErrors} from "src/interfaces/constants/UAgriErrors.sol";
import {UAgriTypes} from "src/interfaces/constants/UAgriTypes.sol";

contract DistCovRewardToken {
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

contract DistCovCompliance {
    bool public allowed = true;
    bool public shouldRevert;

    function setState(bool allowed_, bool shouldRevert_) external {
        allowed = allowed_;
        shouldRevert = shouldRevert_;
    }

    function canTransact(address) external view returns (bool) {
        if (shouldRevert) revert("TX_FAIL");
        return allowed;
    }
}

contract DistCovDisaster {
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

contract DistCovTreasury is IAgriTreasuryV1 {
    address public settlementAsset;
    mapping(uint64 => uint256) public inflowByEpoch;

    constructor(address asset) {
        settlementAsset = asset;
    }

    function availableBalance() external view returns (uint256) {
        return DistCovRewardToken(settlementAsset).balanceOf(address(this));
    }

    function pay(address to, uint256 amount, bytes32 purpose) external {
        bool ok = DistCovRewardToken(settlementAsset).transfer(to, amount);
        require(ok, "TRANSFER_FAIL");
        emit Paid(to, amount, purpose);
    }

    function noteInflow(uint64 epoch, uint256 amount, bytes32 reportHash) external {
        inflowByEpoch[epoch] += amount;
        emit InflowNoted(epoch, amount, reportHash);
    }
}

contract DistCovShareToken {
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

    function setCompliance(address compliance_) external {
        compliance = compliance_;
    }

    function setDisaster(address disaster_) external {
        disaster = disaster_;
    }

    function setTreasury(address treasury_) external {
        treasuryAddr = treasury_;
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

    function setViewGasLimits(UAgriTypes.ViewGasLimits calldata limits) external {
        _gas = limits;
    }

    function callSnapshotOnMint(SnapshotModule module, address to, uint256 amount) external {
        module.onMint(to, amount);
    }

    function callSnapshotOnBurn(SnapshotModule module, address from, uint256 amount) external {
        module.onBurn(from, amount);
    }

    function callSnapshotOnTransfer(SnapshotModule module, address from, address to, uint256 amount) external {
        module.onTransfer(from, to, amount);
    }

    function callYieldOnMint(YieldAccumulator module, address to, uint256 amount) external {
        module.onMint(to, amount);
    }

    function callYieldOnBurn(YieldAccumulator module, address from, uint256 amount) external {
        module.onBurn(from, amount);
    }

    function callYieldOnTransfer(YieldAccumulator module, address from, address to, uint256 amount) external {
        module.onTransfer(from, to, amount);
    }
}

contract DistCovYieldAccumulatorHarness is YieldAccumulator {
    constructor(address roleManager_, address shareToken_, address rewardToken_, bool enforceComplianceOnClaim_)
        YieldAccumulator(roleManager_, shareToken_, rewardToken_, enforceComplianceOnClaim_)
    {}

    function forceHooksState(bool required, bool seen) external {
        requireHooks = required;
        hooksSeen = seen;
    }
}

interface IDistCovReentry {
    function reenter() external;
}

contract DistCovReentrancyProbe is ReentrancyGuard {
    function status() external view returns (uint256) {
        return _reentrancyStatus();
    }

    function callWithGuard(IDistCovReentry target) external nonReentrant {
        target.reenter();
    }

    function reenter() external nonReentrant {}
}

contract DistCovReentryNoop is IDistCovReentry {
    function reenter() external override {}
}

contract DistCovReentryAttacker is IDistCovReentry {
    DistCovReentrancyProbe internal probe;

    constructor(DistCovReentrancyProbe probe_) {
        probe = probe_;
    }

    function attack() external {
        probe.callWithGuard(this);
    }

    function reenter() external override {
        probe.reenter();
    }
}

contract DistributionAndGuardCoverageTest is Test {
    RoleManager internal rm;
    DistCovCompliance internal compliance;
    DistCovDisaster internal disaster;
    DistCovShareToken internal share;
    DistCovRewardToken internal reward;
    DistCovTreasury internal treasuryModule;

    SnapshotModule internal snapshot;
    DistCovYieldAccumulatorHarness internal distribution;

    bytes32 internal campaignId = keccak256("dist-campaign");

    address internal outsider = makeAddr("outsider");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal oracle = makeAddr("oracle");
    address internal farm = makeAddr("farm");
    address internal treasury = makeAddr("treasury");
    address internal governance = makeAddr("governance");
    address internal rewardNotifier = makeAddr("reward-notifier");

    function setUp() public {
        rm = new RoleManager(address(this));
        compliance = new DistCovCompliance();
        disaster = new DistCovDisaster();
        reward = new DistCovRewardToken();
        treasuryModule = new DistCovTreasury(address(reward));
        share = new DistCovShareToken(
            address(rm),
            campaignId,
            address(compliance),
            address(disaster),
            address(treasuryModule)
        );

        snapshot = new SnapshotModule(address(rm), address(share));
        distribution = new DistCovYieldAccumulatorHarness(address(rm), address(share), address(reward), false);

        share.setBalance(alice, 1_000);
        share.setBalance(bob, 500);
        share.setTotalSupply(1_500);

        rm.grantRole(UAgriRoles.ORACLE_UPDATER_ROLE, oracle);
        rm.grantRole(UAgriRoles.FARM_OPERATOR_ROLE, farm);
        rm.grantRole(UAgriRoles.TREASURY_ADMIN_ROLE, treasury);
        rm.grantRole(UAgriRoles.GOVERNANCE_ROLE, governance);
        rm.grantRole(UAgriRoles.REWARD_NOTIFIER_ROLE, rewardNotifier);
    }

    function testReentrancyGuardStatusAndReentryPath() public {
        DistCovReentrancyProbe probe = new DistCovReentrancyProbe();
        assertEq(probe.status(), 1);

        DistCovReentryNoop noop = new DistCovReentryNoop();
        probe.callWithGuard(noop);
        assertEq(probe.status(), 1);

        DistCovReentryAttacker attacker = new DistCovReentryAttacker(probe);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuard__ReentrantCall.selector);
        attacker.attack();
        assertEq(probe.status(), 1);
    }

    function testSnapshotGuardsRolePathsAndHooks() public {
        vm.expectRevert(SnapshotModule.SnapshotModule__AlreadyInitialized.selector);
        snapshot.initialize(address(rm), address(share));

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        snapshot.setSnapshotter(alice, true);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        snapshot.setSnapshotter(address(0), true);

        vm.prank(outsider);
        vm.expectRevert(SnapshotModule.SnapshotModule__UnauthorizedSnapshotter.selector);
        snapshot.snapshotEpoch(1, bytes32(0));

        vm.prank(oracle);
        snapshot.snapshotEpoch(10, keccak256("oracle"));

        vm.prank(farm);
        snapshot.snapshotEpoch(11, keccak256("farm"));

        vm.prank(treasury);
        snapshot.snapshotEpoch(12, keccak256("treasury"));

        vm.prank(governance);
        snapshot.snapshotEpoch(13, keccak256("governance"));

        snapshot.snapshotEpoch(14, keccak256("admin"));

        snapshot.setSnapshotter(alice, true);
        vm.prank(alice);
        uint64 sid1 = snapshot.snapshotEpoch(20, keccak256("sid-1"));

        share.callSnapshotOnTransfer(snapshot, alice, bob, 1);
        share.callSnapshotOnMint(snapshot, alice, 1);

        vm.prank(alice);
        uint64 sid2 = snapshot.snapshotEpoch(21, keccak256("sid-2"));
        share.callSnapshotOnBurn(snapshot, bob, 1);

        assertEq(snapshot.snapshotIdByEpoch(20), sid1);
        assertEq(snapshot.epochBySnapshotId(sid2), 21);
        assertEq(snapshot.balanceOfAt(bob, sid1), 500);
        assertEq(snapshot.totalSupplyAt(sid1), 1_500);

        vm.expectRevert(
            abi.encodeWithSelector(SnapshotModule.SnapshotModule__InvalidSnapshotId.selector, uint64(0))
        );
        snapshot.totalSupplyAt(0);

        vm.expectRevert(
            abi.encodeWithSelector(SnapshotModule.SnapshotModule__InvalidSnapshotId.selector, uint64(0))
        );
        snapshot.balanceOfAtEpoch(alice, 999);

        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        snapshot.onMint(alice, 1);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        share.callSnapshotOnMint(snapshot, address(0), 1);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        share.callSnapshotOnBurn(snapshot, address(0), 1);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        share.callSnapshotOnTransfer(snapshot, address(0), bob, 1);
    }

    function testYieldGuardsNotifierMatrixAndAccountingBranches() public {
        vm.expectRevert(YieldAccumulator.YieldAccumulator__AlreadyInitialized.selector);
        distribution.initialize(address(rm), address(share), address(reward), false);

        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidRoleManager.selector);
        new DistCovYieldAccumulatorHarness(address(0), address(share), address(reward), false);

        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidShareToken.selector);
        new DistCovYieldAccumulatorHarness(address(rm), address(0), address(reward), false);

        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidRewardToken.selector);
        new DistCovYieldAccumulatorHarness(address(rm), address(share), address(0), false);

        RoleManager rm2 = new RoleManager(address(this));
        DistCovShareToken badRmToken = new DistCovShareToken(
            address(rm2),
            campaignId,
            address(compliance),
            address(disaster),
            address(treasuryModule)
        );
        vm.expectRevert(YieldAccumulator.YieldAccumulator__RoleManagerMismatch.selector);
        new DistCovYieldAccumulatorHarness(address(rm), address(badRmToken), address(reward), false);

        DistCovShareToken badCampaignToken = new DistCovShareToken(
            address(rm),
            bytes32(0),
            address(compliance),
            address(disaster),
            address(treasuryModule)
        );
        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidCampaignId.selector);
        new DistCovYieldAccumulatorHarness(address(rm), address(badCampaignToken), address(reward), false);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        distribution.setNotifier(alice, true);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        distribution.setNotifier(address(0), true);

        vm.prank(outsider);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__UnauthorizedNotifier.selector);
        distribution.notifyReward(100, 1, keccak256("unauthorized"));

        share.setTotalSupply(0);
        _fundTreasury(500);
        vm.prank(rewardNotifier);
        distribution.notifyReward(500, 1, keccak256("zero-supply"));
        assertEq(distribution.undistributed(), 500);
        assertEq(distribution.rewardByLiquidationId(1), 500);
        assertEq(distribution.lastLiquidationId(), 1);

        share.setTotalSupply(1_500);

        vm.prank(oracle);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__UnauthorizedNotifier.selector);
        distribution.notifyReward(100, 2, keccak256("oracle"));

        vm.prank(farm);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__UnauthorizedNotifier.selector);
        distribution.notifyReward(100, 2, keccak256("farm"));

        vm.prank(treasury);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__UnauthorizedNotifier.selector);
        distribution.notifyReward(100, 2, keccak256("treasury"));

        distribution.setNotifier(alice, true);
        vm.prank(alice);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__UnauthorizedNotifier.selector);
        distribution.notifyReward(100, 2, keccak256("allowlisted"));

        _fundTreasury(100);
        vm.prank(governance);
        distribution.notifyReward(100, 2, keccak256("governance"));

        _fundTreasury(100);
        distribution.notifyReward(100, 3, keccak256("admin"));

        _fundTreasury(100);
        vm.prank(rewardNotifier);
        distribution.notifyReward(100, 4, keccak256("reward-notifier"));

        assertGt(distribution.pending(alice), 0);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        distribution.claimFor(address(0));

        uint256 paidForAlice = distribution.claimFor(alice);
        assertGt(paidForAlice, 0);
        assertEq(reward.balanceOf(alice), paidForAlice);

        vm.prank(bob);
        uint256 paidForBob = distribution.claim();
        assertGt(paidForBob, 0);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        distribution.recoverERC20(address(0), alice, 1);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAmount.selector);
        distribution.recoverERC20(address(reward), alice, 0);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        distribution.recoverERC20(address(reward), outsider, 1);

        distribution.forceHooksState(true, false);
        _fundTreasury(100);
        vm.prank(rewardNotifier);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__HooksRequired.selector);
        distribution.notifyReward(100, 5, keccak256("hooks-guard"));

        vm.expectRevert(UAgriErrors.UAgri__InvalidAddress.selector);
        share.callYieldOnTransfer(distribution, address(0), alice, 1);
    }

    function _fundTreasury(uint256 amount) internal {
        reward.mint(address(treasuryModule), amount);
    }
}
