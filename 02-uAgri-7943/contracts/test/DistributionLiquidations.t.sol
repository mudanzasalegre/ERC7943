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

contract DistLiqERC20 {
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
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
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

contract DistLiqTreasury is IAgriTreasuryV1 {
    address public settlementAsset;
    mapping(uint64 => uint256) public inflowByEpoch;

    constructor(address asset) {
        settlementAsset = asset;
    }

    function availableBalance() external view returns (uint256) {
        return DistLiqERC20(settlementAsset).balanceOf(address(this));
    }

    function pay(address to, uint256 amount, bytes32 purpose) external {
        bool ok = DistLiqERC20(settlementAsset).transfer(to, amount);
        require(ok, "TRANSFER_FAIL");
        emit Paid(to, amount, purpose);
    }

    function noteInflow(uint64 epoch, uint256 amount, bytes32 reportHash) external {
        inflowByEpoch[epoch] += amount;
        emit InflowNoted(epoch, amount, reportHash);
    }
}

contract DistLiqCompliance {
    bool public allowed = true;

    function setAllowed(bool v) external {
        allowed = v;
    }

    function canTransact(address) external view returns (bool) {
        return allowed;
    }
}

contract DistLiqDisaster {
    uint256 public flags;
    bool public restricted;
    bool public hardFrozen;
    bool public shouldRevert;

    function setState(uint256 flags_, bool restricted_, bool hardFrozen_) external {
        flags = flags_;
        restricted = restricted_;
        hardFrozen = hardFrozen_;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function campaignFlags(bytes32) external view returns (uint256) {
        if (shouldRevert) revert("FLAGS_FAIL");
        return flags;
    }

    function isRestricted(bytes32) external view returns (bool) {
        if (shouldRevert) revert("RES_FAIL");
        return restricted;
    }

    function isHardFrozen(bytes32) external view returns (bool) {
        if (shouldRevert) revert("FREEZE_FAIL");
        return hardFrozen;
    }
}

contract DistLiqShareToken {
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

contract DistributionLiquidationsTest is Test {
    RoleManager internal rm;
    DistLiqERC20 internal usdc;
    DistLiqTreasury internal treasury;
    DistLiqCompliance internal compliance;
    DistLiqDisaster internal disaster;
    DistLiqShareToken internal share;
    YieldAccumulator internal yieldAcc;

    bytes32 internal campaignId = keccak256("distribution-liquidations");

    address internal notifier = makeAddr("notifier");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        rm = new RoleManager(address(this));
        usdc = new DistLiqERC20();
        treasury = new DistLiqTreasury(address(usdc));
        compliance = new DistLiqCompliance();
        disaster = new DistLiqDisaster();

        share = new DistLiqShareToken(
            address(rm),
            campaignId,
            address(compliance),
            address(disaster),
            address(treasury)
        );
        share.setTotalSupply(1_000_000);
        share.setBalance(alice, 600_000);
        share.setBalance(bob, 400_000);

        yieldAcc = new YieldAccumulator(address(rm), address(share), address(usdc), false);
        rm.grantRole(UAgriRoles.REWARD_NOTIFIER_ROLE, notifier);
    }

    function testNotifyReward_requiresSequentialLiquidationId() public {
        _fundTreasury(300_000);

        vm.prank(notifier);
        yieldAcc.notifyReward(100_000, 1, keccak256("liquidation-1"));
        assertEq(yieldAcc.lastLiquidationId(), 1);

        vm.prank(notifier);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidLiquidationId.selector);
        yieldAcc.notifyReward(100_000, 1, keccak256("liquidation-1-replay"));

        vm.prank(notifier);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidLiquidationId.selector);
        yieldAcc.notifyReward(100_000, 3, keccak256("liquidation-3-gap"));
    }

    function testNotifyReward_pullsFromTreasury() public {
        uint256 liquidationId = yieldAcc.nextLiquidationId();
        bytes32 reportHash = keccak256("liquidation-report");

        _fundTreasury(200_000);
        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        uint256 yieldBefore = usdc.balanceOf(address(yieldAcc));

        vm.prank(notifier);
        yieldAcc.notifyReward(200_000, uint64(liquidationId), reportHash);

        assertEq(usdc.balanceOf(address(treasury)), treasuryBefore - 200_000);
        assertEq(usdc.balanceOf(address(yieldAcc)), yieldBefore + 200_000);
        assertEq(yieldAcc.rewardByLiquidationId(liquidationId), 200_000);
        assertEq(yieldAcc.reportHashByLiquidationId(liquidationId), reportHash);
    }

    function testNotifyReward_requiresNonZeroReportHash() public {
        _fundTreasury(100_000);

        vm.prank(notifier);
        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidReportHash.selector);
        yieldAcc.notifyReward(100_000, 1, bytes32(0));
    }

    function testClaim_blockedByPauseClaimsFlag() public {
        _fundTreasury(100_000);
        vm.prank(notifier);
        yieldAcc.notifyReward(100_000, 1, keccak256("liquidation-1"));
        assertGt(yieldAcc.pending(alice), 0);

        disaster.setState(UAgriFlags.PAUSE_CLAIMS, false, false);

        vm.prank(alice);
        vm.expectRevert(UAgriErrors.UAgri__Paused.selector);
        yieldAcc.claim();
    }

    function _fundTreasury(uint256 amount) internal {
        usdc.mint(address(treasury), amount);
    }
}
