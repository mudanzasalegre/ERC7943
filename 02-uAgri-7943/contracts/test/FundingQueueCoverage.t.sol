// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {FundingManager} from "src/campaign/FundingManager.sol";
import {SettlementQueue} from "src/campaign/SettlementQueue.sol";

import {IAgriModulesV1} from "src/interfaces/v1/IAgriModulesV1.sol";
import {IAgriCampaignRegistryV1} from "src/interfaces/v1/IAgriCampaignRegistryV1.sol";
import {IAgriTreasuryV1} from "src/interfaces/v1/IAgriTreasuryV1.sol";
import {ISettlementQueueV1} from "src/interfaces/v1/ISettlementQueueV1.sol";
import {IAgriDisasterV1} from "src/interfaces/v1/IAgriDisasterV1.sol";
import {IAgriComplianceV1} from "src/interfaces/v1/IAgriComplianceV1.sol";
import {IAgriCustodyV1} from "src/interfaces/v1/IAgriCustodyV1.sol";

import {UAgriTypes} from "src/interfaces/constants/UAgriTypes.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";
import {UAgriFlags} from "src/interfaces/constants/UAgriFlags.sol";
import {UAgriErrors} from "src/interfaces/constants/UAgriErrors.sol";

contract CovERC20 {
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

contract CovNoDecimalsAsset {
    fallback() external payable {}
}

contract CovTreasury is IAgriTreasuryV1 {
    address public settlementAsset;
    mapping(uint64 => uint256) public inflowByEpoch;

    constructor(address asset) {
        settlementAsset = asset;
    }

    function setSettlementAsset(address asset) external {
        settlementAsset = asset;
    }

    function availableBalance() external view returns (uint256) {
        return CovERC20(settlementAsset).balanceOf(address(this));
    }

    function pay(address to, uint256 amount, bytes32 purpose) external {
        bool ok = CovERC20(settlementAsset).transfer(to, amount);
        require(ok, "TRANSFER_FAIL");
        emit Paid(to, amount, purpose);
    }

    function noteInflow(uint64 epoch, uint256 amount, bytes32 reportHash) external {
        inflowByEpoch[epoch] += amount;
        emit InflowNoted(epoch, amount, reportHash);
    }
}

contract CovCampaignRegistry is IAgriCampaignRegistryV1 {
    UAgriTypes.Campaign internal _campaign;

    constructor(bytes32 campaignId, address settlementAsset, uint256 cap, UAgriTypes.CampaignState st) {
        _campaign = UAgriTypes.Campaign({
            campaignId: campaignId,
            plotRef: bytes32(0),
            subPlotId: bytes32(0),
            areaBps: 0,
            startTs: 0,
            endTs: 0,
            settlementAsset: settlementAsset,
            fundingCap: cap,
            docsRootHash: bytes32(0),
            jurisdictionProfile: bytes32(0),
            state: st
        });
    }

    function setState(UAgriTypes.CampaignState st) external {
        _campaign.state = st;
    }

    function setFundingCap(uint256 cap) external {
        _campaign.fundingCap = cap;
    }

    function getCampaign(bytes32) external view returns (UAgriTypes.Campaign memory) {
        return _campaign;
    }

    function state(bytes32) external view returns (UAgriTypes.CampaignState) {
        return _campaign.state;
    }
}

contract CovDisasterModule is IAgriDisasterV1 {
    uint256 public flags;
    bool public restricted;
    bool public hardFrozen;
    bool public shouldRevert;

    function setState(uint256 f, bool r, bool h, bool reverts) external {
        flags = f;
        restricted = r;
        hardFrozen = h;
        shouldRevert = reverts;
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

contract CovComplianceModule is IAgriComplianceV1 {
    bool public canTransactResult = true;
    bool public canTransferResult = true;
    bool public revertTransact;
    bool public revertTransfer;

    function setState(bool txOk, bool trOk, bool revTx, bool revTr) external {
        canTransactResult = txOk;
        canTransferResult = trOk;
        revertTransact = revTx;
        revertTransfer = revTr;
    }

    function canTransact(address) external view returns (bool ok) {
        if (revertTransact) revert("TX_FAIL");
        return canTransactResult;
    }

    function canTransfer(address, address, uint256) external view returns (bool ok) {
        if (revertTransfer) revert("TR_FAIL");
        return canTransferResult;
    }

    function transferStatus(address, address, uint256) external pure returns (bool ok, uint8 code) {
        return (true, 0);
    }
}

contract CovCustodyModule is IAgriCustodyV1 {
    bool public fresh = true;
    bool public shouldRevert;

    function setState(bool isFresh, bool reverts) external {
        fresh = isFresh;
        shouldRevert = reverts;
    }

    function isCustodyFresh(bytes32) external view returns (bool) {
        if (shouldRevert) revert("CUSTODY_FAIL");
        return fresh;
    }

    function lastCustodyEpoch(bytes32) external pure returns (uint64) {
        return 0;
    }

    function custodyValidUntil(bytes32) external pure returns (uint64) {
        return 0;
    }
}

contract CovShareTokenFunding is IAgriModulesV1 {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    uint8 internal _decimals;
    bool public revertDecimals;
    bytes32 public campaignId;
    address public roleManager;

    address public compliance;
    address public disaster;
    address public freeze;
    address public custody;
    address public treasuryAddr;

    UAgriTypes.ViewGasLimits internal _gas;

    constructor(
        address roleManager_,
        bytes32 campaignId_,
        uint8 decimals_,
        address compliance_,
        address disaster_,
        address custody_,
        address treasury_
    ) {
        roleManager = roleManager_;
        campaignId = campaignId_;
        _decimals = decimals_;
        compliance = compliance_;
        disaster = disaster_;
        custody = custody_;
        treasuryAddr = treasury_;
        _gas = UAgriTypes.ViewGasLimits({
            complianceGas: 100_000,
            disasterGas: 100_000,
            freezeGas: 100_000,
            custodyGas: 100_000,
            extraGas: 100_000
        });
    }

    function setRevertDecimals(bool v) external {
        revertDecimals = v;
    }

    function setTreasury(address t) external {
        treasuryAddr = t;
    }

    function setCompliance(address c) external {
        compliance = c;
    }

    function setDisaster(address d) external {
        disaster = d;
    }

    function setCustody(address c) external {
        custody = c;
    }

    function setViewGas(UAgriTypes.ViewGasLimits memory g) external {
        _gas = g;
    }

    function decimals() external view returns (uint8) {
        if (revertDecimals) revert("DEC_FAIL");
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        uint256 b = balanceOf[from];
        require(b >= amount, "BURN_BAL");
        balanceOf[from] = b - amount;
        totalSupply -= amount;
    }

    function complianceModule() external view returns (address) { return compliance; }
    function disasterModule() external view returns (address) { return disaster; }
    function freezeModule() external view returns (address) { return freeze; }
    function custodyModule() external view returns (address) { return custody; }
    function traceModule() external pure returns (address) { return address(0); }
    function documentRegistry() external pure returns (address) { return address(0); }
    function settlementQueue() external pure returns (address) { return address(0); }
    function treasury() external view returns (address) { return treasuryAddr; }
    function distribution() external pure returns (address) { return address(0); }
    function bridgeModule() external pure returns (address) { return address(0); }
    function marketplaceModule() external pure returns (address) { return address(0); }
    function deliveryModule() external pure returns (address) { return address(0); }
    function insuranceModule() external pure returns (address) { return address(0); }
    function viewGasLimits() external view returns (UAgriTypes.ViewGasLimits memory) { return _gas; }
    function setViewGasLimits(UAgriTypes.ViewGasLimits calldata) external {}
}

contract CovQueueForFunding is ISettlementQueueV1 {
    uint256 public nextId;
    mapping(uint256 => UAgriTypes.Request) public req;

    function setRequest(
        uint256 id,
        address account,
        uint8 kind,
        uint256 amount,
        uint256 minOut,
        uint256 maxIn,
        uint64 deadline,
        uint8 status
    ) external {
        req[id] = UAgriTypes.Request({
            account: account,
            kind: UAgriTypes.RequestKind(kind),
            amount: amount,
            minOut: minOut,
            maxIn: maxIn,
            deadline: deadline,
            status: UAgriTypes.RequestStatus(status)
        });
    }

    function requestDeposit(uint256 amountIn, uint256 maxIn, uint64 deadline) external returns (uint256 id) {
        id = ++nextId;
        req[id] = UAgriTypes.Request({
            account: msg.sender,
            kind: UAgriTypes.RequestKind.Deposit,
            amount: amountIn,
            minOut: maxIn,
            maxIn: 0,
            deadline: deadline,
            status: UAgriTypes.RequestStatus.Requested
        });
    }

    function requestRedeem(uint256 shares, uint256 minOut, uint64 deadline) external returns (uint256 id) {
        id = ++nextId;
        req[id] = UAgriTypes.Request({
            account: msg.sender,
            kind: UAgriTypes.RequestKind.Redeem,
            amount: shares,
            minOut: minOut,
            maxIn: 0,
            deadline: deadline,
            status: UAgriTypes.RequestStatus.Requested
        });
    }

    function cancel(uint256) external {}
    function batchProcess(uint256[] calldata, uint64, bytes32) external {}

    function getRequest(uint256 id) external view returns (UAgriTypes.Request memory) {
        return req[id];
    }
}

contract CovFundingHarness is FundingManager {
    constructor(
        address roleManager_,
        bytes32 campaignId_,
        address shareToken_,
        address registry_,
        address settlementQueue_,
        uint16 depositFeeBps_,
        uint16 redeemFeeBps_,
        address feeRecipient_,
        bool allowDepositsWhenActive_,
        bool allowRedeemsDuringFunding_,
        bool enforceCustodyFreshOnRedeem_
    )
        FundingManager(
            roleManager_,
            campaignId_,
            shareToken_,
            registry_,
            settlementQueue_,
            depositFeeBps_,
            redeemFeeBps_,
            feeRecipient_,
            allowDepositsWhenActive_,
            allowRedeemsDuringFunding_,
            enforceCustodyFreshOnRedeem_
        )
    {}

    function exposedMulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return _mulDiv(x, y, d);
    }

    function exposedMulDivRoundingUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return _mulDivRoundingUp(x, y, d);
    }

    function forceFeeRecipient(address fr) external {
        feeRecipient = fr;
    }
}

contract CovFundingManagerQueueMock {
    bool public shouldRevert;
    uint256 public outAmount = 777;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setOutAmount(uint256 out) external {
        outAmount = out;
    }

    function settleFromQueue(uint256, bytes32) external view returns (uint256 out) {
        if (shouldRevert) revert("FM_FAIL");
        return outAmount;
    }
}

contract FundingManagerCoverageTest is Test {
    RoleManager internal rm;
    CovERC20 internal asset;
    CovTreasury internal treasury;
    CovCampaignRegistry internal registry;
    CovDisasterModule internal disaster;
    CovComplianceModule internal compliance;
    CovCustodyModule internal custody;
    CovShareTokenFunding internal share;
    CovQueueForFunding internal queue;
    CovFundingHarness internal manager;

    bytes32 internal campaignId = keccak256("funding-campaign");
    address internal alice = makeAddr("alice");
    address internal outsider = makeAddr("outsider");
    address internal feeReceiver = makeAddr("fee-receiver");

    function setUp() public {
        rm = new RoleManager(address(this));
        asset = new CovERC20(6);
        treasury = new CovTreasury(address(asset));
        registry = new CovCampaignRegistry(campaignId, address(asset), type(uint256).max, UAgriTypes.CampaignState.FUNDING);
        disaster = new CovDisasterModule();
        compliance = new CovComplianceModule();
        custody = new CovCustodyModule();
        queue = new CovQueueForFunding();

        share = new CovShareTokenFunding(
            address(rm),
            campaignId,
            6,
            address(compliance),
            address(disaster),
            address(custody),
            address(treasury)
        );

        manager = new CovFundingHarness(
            address(rm),
            campaignId,
            address(share),
            address(registry),
            address(queue),
            0,
            0,
            address(0),
            false,
            true,
            false
        );
    }

    function testFundingInitGovernanceAndRequestWrappers() public {
        vm.expectRevert(FundingManager.FundingManager__InvalidConfig.selector);
        new CovFundingHarness(
            address(rm),
            campaignId,
            address(share),
            address(registry),
            address(queue),
            1,
            0,
            address(0),
            false,
            true,
            false
        );

        vm.expectRevert(FundingManager.FundingManager__AlreadyInitialized.selector);
        manager.initialize(
            address(rm),
            campaignId,
            address(share),
            address(registry),
            address(queue),
            0,
            0,
            address(0),
            false,
            true,
            false
        );

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        manager.setFees(0, 0, address(0));

        manager.setSettlementQueue(address(0));
        vm.expectRevert(FundingManager.FundingManager__InvalidSettlementQueue.selector);
        manager.requestDeposit(1, 0, 0);
        vm.expectRevert(FundingManager.FundingManager__InvalidSettlementQueue.selector);
        manager.requestRedeem(1, 0, 0);

        manager.setSettlementQueue(address(queue));
        manager.refreshSettlementAssetAndUnits();

        uint256 depId = manager.requestDeposit(123, 7, uint64(block.timestamp + 1 days));
        uint256 redId = manager.requestRedeem(456, 8, uint64(block.timestamp + 1 days));
        assertEq(depId, 1);
        assertEq(redId, 2);
    }

    function testFundingSettlementBranchingAndProcessorGuards() public {
        vm.warp(100);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        manager.settleDepositExactAssets(alice, 1, 0, 0, bytes32(0));

        queue.setRequest(1, alice, 0, 10, 0, 0, 0, uint8(UAgriTypes.RequestStatus.Cancelled));
        vm.expectRevert(UAgriErrors.UAgri__BadState.selector);
        manager.settleFromQueue(1, keccak256("bad-state"));

        queue.setRequest(
            2,
            alice,
            0,
            10,
            0,
            0,
            uint64(block.timestamp - 1),
            uint8(UAgriTypes.RequestStatus.Requested)
        );
        vm.expectRevert(UAgriErrors.UAgri__DeadlineExpired.selector);
        manager.settleFromQueue(2, keccak256("expired"));

        asset.mint(alice, 1_000_000);
        vm.prank(alice);
        asset.approve(address(manager), type(uint256).max);

        queue.setRequest(4, alice, 0, 100_000, 0, 0, 0, uint8(UAgriTypes.RequestStatus.Requested));
        uint256 out = manager.settleFromQueue(4, keccak256("ok-deposit"));
        assertEq(out, 100_000);

        vm.expectRevert(abi.encodeWithSelector(FundingManager.FundingManager__RequestAlreadySettled.selector, uint256(4)));
        manager.settleFromQueue(4, keccak256("again"));
    }

    function testFundingDepositRedeemModesPoliciesAndFees() public {
        vm.warp(100);
        manager.setFees(100, 100, feeReceiver);

        asset.mint(alice, 5_000_000);
        vm.prank(alice);
        asset.approve(address(manager), type(uint256).max);

        queue.setRequest(11, alice, 0, 500_000, 0, 600_000, 0, uint8(UAgriTypes.RequestStatus.Requested));
        uint256 minted = manager.settleFromQueue(11, keccak256("dep-exact-shares"));
        assertEq(minted, 500_000);
        assertGt(asset.balanceOf(feeReceiver), 0);

        queue.setRequest(12, alice, 0, 500_000, 0, 10, 0, uint8(UAgriTypes.RequestStatus.Requested));
        vm.expectRevert();
        manager.settleFromQueue(12, keccak256("dep-maxin"));

        vm.expectRevert(UAgriErrors.UAgri__DeadlineExpired.selector);
        manager.settleDepositExactAssets(alice, 100, 0, uint64(block.timestamp - 1), keccak256("dep-deadline"));

        vm.expectRevert();
        manager.depositInstant(100_000, 200_000, 0, keccak256("dep-minout"));

        disaster.setState(UAgriFlags.PAUSE_FUNDING, false, false, false);
        vm.expectRevert(UAgriErrors.UAgri__Paused.selector);
        manager.depositInstant(100_000, 0, 0, keccak256("paused-funding"));

        disaster.setState(0, true, false, false);
        vm.expectRevert(UAgriErrors.UAgri__Restricted.selector);
        manager.depositInstant(100_000, 0, 0, keccak256("restricted"));

        disaster.setState(0, false, true, false);
        vm.expectRevert(UAgriErrors.UAgri__HardFrozen.selector);
        manager.depositInstant(100_000, 0, 0, keccak256("hard-frozen"));

        disaster.setState(0, false, false, false);
        compliance.setState(false, true, false, false);
        vm.expectRevert(UAgriErrors.UAgri__ComplianceDenied.selector);
        manager.depositInstant(100_000, 0, 0, keccak256("compliance-denied"));

        compliance.setState(true, true, false, false);
        registry.setFundingCap(10_000);
        vm.expectRevert();
        manager.depositInstant(20_000, 0, 0, keccak256("cap"));
        registry.setFundingCap(type(uint256).max);

        registry.setState(UAgriTypes.CampaignState.ACTIVE);
        vm.expectRevert(UAgriErrors.UAgri__BadState.selector);
        manager.depositInstant(1, 0, 0, keccak256("active-disallowed"));
        manager.setPolicyToggles(true, true, false);
        vm.prank(alice);
        manager.depositInstant(1, 0, 0, keccak256("active-allowed"));

        treasury.setSettlementAsset(address(asset));
        asset.mint(address(treasury), 5_000_000);

        vm.expectRevert(UAgriErrors.UAgri__DeadlineExpired.selector);
        manager.settleRedeemExactShares(alice, 1, 0, uint64(block.timestamp - 1), keccak256("red-deadline"));

        vm.expectRevert();
        manager.redeemInstant(10_000, type(uint256).max, 0, keccak256("red-minout"));

        queue.setRequest(13, alice, 1, 10_000, 0, 0, 0, uint8(UAgriTypes.RequestStatus.Requested));
        uint256 assetsOut = manager.settleFromQueue(13, keccak256("red-exact-shares"));
        assertGt(assetsOut, 0);

        queue.setRequest(14, alice, 1, 50_000, 0, 10, 0, uint8(UAgriTypes.RequestStatus.Requested));
        vm.expectRevert();
        manager.settleFromQueue(14, keccak256("red-maxin"));

        queue.setRequest(15, alice, 1, 1_000, 0, 100_000, 0, uint8(UAgriTypes.RequestStatus.Requested));
        assertEq(manager.settleFromQueue(15, keccak256("red-exact-assets")), 1_000);

        manager.setPolicyToggles(true, true, true);
        custody.setState(false, false);
        vm.expectRevert(UAgriErrors.UAgri__CustodyStale.selector);
        manager.redeemInstant(1, 0, 0, keccak256("custody-stale"));

        custody.setState(true, true);
        vm.expectRevert(UAgriErrors.UAgri__FailClosed.selector);
        manager.redeemInstant(1, 0, 0, keccak256("custody-failclosed"));

        custody.setState(true, false);
        share.setCustody(address(0));
        vm.expectRevert(FundingManager.FundingManager__InvalidConfig.selector);
        manager.redeemInstant(1, 0, 0, keccak256("custody-missing"));
        share.setCustody(address(custody));

        disaster.setState(UAgriFlags.PAUSE_REDEMPTIONS, false, false, false);
        vm.expectRevert(UAgriErrors.UAgri__Paused.selector);
        manager.redeemInstant(1, 0, 0, keccak256("paused-redeem"));
        disaster.setState(0, false, false, false);

        manager.forceFeeRecipient(address(0));
        vm.expectRevert(FundingManager.FundingManager__InvalidConfig.selector);
        vm.prank(alice);
        manager.redeemInstant(100, 0, 0, keccak256("fee-zero"));
    }

    function testFundingFeeRecipientTreasuryBranchesAndMath() public {
        manager.setFees(100, 0, address(treasury));

        asset.mint(alice, 1_000_000);
        vm.startPrank(alice);
        asset.approve(address(manager), type(uint256).max);
        manager.depositInstant(100_000, 0, 0, keccak256("fee-to-treasury"));
        vm.stopPrank();

        manager.setFees(100, 0, feeReceiver);

        vm.startPrank(alice);
        manager.depositInstant(100_000, 0, 0, keccak256("fee-to-receiver"));
        vm.stopPrank();
        assertGt(asset.balanceOf(feeReceiver), 0);

        uint256 small = manager.exposedMulDiv(9, 10, 4);
        assertEq(small, 22);

        uint256 big = manager.exposedMulDiv(type(uint256).max, type(uint256).max, type(uint256).max);
        assertEq(big, type(uint256).max);

        uint256 rounded = manager.exposedMulDivRoundingUp(10, 10, 3);
        assertEq(rounded, 34);
    }

    function testFundingDecimalDetectionFallbacks() public {
        share.setRevertDecimals(true);
        manager.refreshSettlementAssetAndUnits();
        share.setRevertDecimals(false);

        CovNoDecimalsAsset noDec = new CovNoDecimalsAsset();
        treasury.setSettlementAsset(address(noDec));
        manager.refreshSettlementAssetAndUnits();

        CovERC20 overDec = new CovERC20(30);
        treasury.setSettlementAsset(address(overDec));
        manager.refreshSettlementAssetAndUnits();

        treasury.setSettlementAsset(address(asset));
        manager.refreshSettlementAssetAndUnits();
    }
}

contract SettlementQueueCoverageTest is Test {
    RoleManager internal rm;
    CovFundingManagerQueueMock internal fm;
    SettlementQueue internal queue;

    bytes32 internal campaignId = keccak256("queue-campaign");
    address internal outsider = makeAddr("outsider");
    address internal alice = makeAddr("alice");
    address internal operator = makeAddr("operator");

    function setUp() public {
        rm = new RoleManager(address(this));
        fm = new CovFundingManagerQueueMock();
        queue = new SettlementQueue(address(rm), campaignId, address(fm), false);
        rm.grantRole(UAgriRoles.FARM_OPERATOR_ROLE, operator);
    }

    function testQueueInitGovernanceAndRequestBuilders() public {
        vm.warp(100);

        vm.expectRevert(SettlementQueue.SettlementQueue__AlreadyInitialized.selector);
        queue.initialize(address(rm), campaignId, address(fm), false);

        vm.expectRevert(SettlementQueue.SettlementQueue__InvalidRoleManager.selector);
        new SettlementQueue(address(0), campaignId, address(fm), false);
        vm.expectRevert(SettlementQueue.SettlementQueue__InvalidCampaignId.selector);
        new SettlementQueue(address(rm), bytes32(0), address(fm), false);
        vm.expectRevert(SettlementQueue.SettlementQueue__InvalidFundingManager.selector);
        new SettlementQueue(address(rm), campaignId, address(0), false);

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        queue.setFundingManager(address(1));

        vm.expectRevert(SettlementQueue.SettlementQueue__InvalidFundingManager.selector);
        queue.setFundingManager(address(0));
        queue.setFundingManager(address(fm));

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        queue.setDepositExactSharesMode(true);
        queue.setDepositExactSharesMode(true);

        vm.expectRevert(UAgriErrors.UAgri__InvalidAmount.selector);
        queue.requestDeposit(0, 0, 0);
        vm.expectRevert(UAgriErrors.UAgri__DeadlineExpired.selector);
        queue.requestDeposit(1, 0, uint64(block.timestamp - 1));

        vm.expectRevert(UAgriErrors.UAgri__InvalidAmount.selector);
        queue.requestDepositExactAssets(0, 0, 0);
        vm.expectRevert(UAgriErrors.UAgri__DeadlineExpired.selector);
        queue.requestDepositExactAssets(1, 0, uint64(block.timestamp - 1));

        vm.expectRevert(UAgriErrors.UAgri__InvalidAmount.selector);
        queue.requestDepositExactShares(0, 1, 0);
        vm.expectRevert(UAgriErrors.UAgri__InvalidAmount.selector);
        queue.requestDepositExactShares(1, 0, 0);
        vm.expectRevert(UAgriErrors.UAgri__DeadlineExpired.selector);
        queue.requestDepositExactShares(1, 1, uint64(block.timestamp - 1));

        vm.expectRevert(UAgriErrors.UAgri__InvalidAmount.selector);
        queue.requestRedeem(0, 0, 0);
        vm.expectRevert(UAgriErrors.UAgri__DeadlineExpired.selector);
        queue.requestRedeem(1, 0, uint64(block.timestamp - 1));

        uint256 id1 = queue.requestDeposit(100, 7, uint64(block.timestamp + 1 days));
        assertEq(id1, 1);
        assertEq(queue.requestCount(), 1);

        queue.setDepositExactSharesMode(true);
        vm.expectRevert(UAgriErrors.UAgri__InvalidAmount.selector);
        queue.requestDeposit(100, 0, uint64(block.timestamp + 1 days));
        uint256 id2 = queue.requestDeposit(100, 150, uint64(block.timestamp + 1 days));
        assertEq(id2, 2);
    }

    function testQueueCancelGetAndBatchProcessBranches() public {
        vm.warp(100);

        vm.expectRevert(UAgriErrors.UAgri__RequestNotFound.selector);
        queue.getRequest(999);
        vm.expectRevert(UAgriErrors.UAgri__RequestNotFound.selector);
        queue.cancel(999);

        uint256 id = queue.requestRedeem(100, 0, uint64(block.timestamp + 1 days));

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        queue.cancel(id);

        vm.prank(operator);
        queue.cancel(id);

        vm.expectRevert(UAgriErrors.UAgri__RequestNotCancellable.selector);
        queue.cancel(id);

        uint256 idOk = queue.requestDeposit(100, 0, uint64(block.timestamp + 1 days));
        uint256 idFail = queue.requestDeposit(200, 0, uint64(block.timestamp + 1 days));
        uint256 idExpired = queue.requestDeposit(300, 0, uint64(block.timestamp + 1));
        vm.warp(block.timestamp + 2);

        uint256[] memory ids = new uint256[](1);
        ids[0] = idExpired;
        vm.prank(operator);
        queue.batchProcess(ids, 1, keccak256("exp"));
        UAgriTypes.Request memory rExp = queue.getRequest(idExpired);
        assertEq(uint256(rExp.status), uint256(UAgriTypes.RequestStatus.Cancelled));

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        queue.batchProcess(ids, 1, keccak256("unauth"));

        fm.setOutAmount(999);
        ids = new uint256[](1);
        ids[0] = idOk;
        vm.prank(operator);
        queue.batchProcess(ids, 2, keccak256("ok"));
        UAgriTypes.Request memory rOk = queue.getRequest(idOk);
        assertEq(uint256(rOk.status), uint256(UAgriTypes.RequestStatus.Processed));

        fm.setShouldRevert(true);
        ids[0] = idFail;
        vm.prank(operator);
        queue.batchProcess(ids, 3, keccak256("fail"));
        UAgriTypes.Request memory rFail = queue.getRequest(idFail);
        assertEq(uint256(rFail.status), uint256(UAgriTypes.RequestStatus.Requested));

        vm.store(address(queue), bytes32(uint256(3)), bytes32(0));
        vm.prank(operator);
        vm.expectRevert(SettlementQueue.SettlementQueue__InvalidFundingManager.selector);
        queue.batchProcess(ids, 3, keccak256("bad-fm"));

        queue.setFundingManager(address(fm));
        uint256[] memory badIds = new uint256[](1);
        badIds[0] = 4242;
        vm.prank(operator);
        vm.expectRevert(UAgriErrors.UAgri__RequestNotFound.selector);
        queue.batchProcess(badIds, 4, keccak256("missing"));
    }
}
