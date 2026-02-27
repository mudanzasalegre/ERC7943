// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {FundingManager} from "src/campaign/FundingManager.sol";

import {IAgriModulesV1} from "src/interfaces/v1/IAgriModulesV1.sol";
import {IAgriCampaignRegistryV1} from "src/interfaces/v1/IAgriCampaignRegistryV1.sol";
import {IAgriComplianceV1} from "src/interfaces/v1/IAgriComplianceV1.sol";
import {IAgriDisasterV1} from "src/interfaces/v1/IAgriDisasterV1.sol";
import {IAgriTreasuryV1} from "src/interfaces/v1/IAgriTreasuryV1.sol";

import {UAgriTypes} from "src/interfaces/constants/UAgriTypes.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";
import {UAgriErrors} from "src/interfaces/constants/UAgriErrors.sol";

contract OnRampERC20Mock {
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
        require(a >= amount, "ALLOWANCE");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "TO_ZERO");
        uint256 b = balanceOf[from];
        require(b >= amount, "BALANCE");
        unchecked {
            balanceOf[from] = b - amount;
            balanceOf[to] += amount;
        }
    }
}

contract OnRampTreasuryMock is IAgriTreasuryV1 {
    address public settlementAsset;
    mapping(uint64 => uint256) public inflowByEpoch;

    constructor(address asset) {
        settlementAsset = asset;
    }

    function availableBalance() external view returns (uint256) {
        return OnRampERC20Mock(settlementAsset).balanceOf(address(this));
    }

    function pay(address to, uint256 amount, bytes32 purpose) external {
        bool ok = OnRampERC20Mock(settlementAsset).transfer(to, amount);
        require(ok, "TRANSFER_FAIL");
        emit Paid(to, amount, purpose);
    }

    function noteInflow(uint64 epoch, uint256 amount, bytes32 reportHash) external {
        inflowByEpoch[epoch] += amount;
        emit InflowNoted(epoch, amount, reportHash);
    }
}

contract OnRampRegistryMock is IAgriCampaignRegistryV1 {
    UAgriTypes.Campaign internal _campaign;

    constructor(bytes32 campaignId, address settlementAsset, uint256 fundingCap, UAgriTypes.CampaignState st) {
        _campaign = UAgriTypes.Campaign({
            campaignId: campaignId,
            plotRef: bytes32(0),
            subPlotId: bytes32(0),
            areaBps: 0,
            startTs: 0,
            endTs: 0,
            settlementAsset: settlementAsset,
            fundingCap: fundingCap,
            docsRootHash: bytes32(0),
            jurisdictionProfile: bytes32(0),
            state: st
        });
    }

    function setFundingCap(uint256 cap) external {
        _campaign.fundingCap = cap;
    }

    function setState(UAgriTypes.CampaignState st) external {
        _campaign.state = st;
    }

    function getCampaign(bytes32) external view returns (UAgriTypes.Campaign memory) {
        return _campaign;
    }

    function state(bytes32) external view returns (UAgriTypes.CampaignState) {
        return _campaign.state;
    }
}

contract OnRampDisasterMock is IAgriDisasterV1 {
    uint256 public flags;
    bool public restricted;
    bool public hardFrozen;

    function setState(uint256 f, bool r, bool h) external {
        flags = f;
        restricted = r;
        hardFrozen = h;
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

contract OnRampComplianceMock is IAgriComplianceV1 {
    mapping(address => bool) public canByAccount;

    function setCanTransact(address account, bool allowed) external {
        canByAccount[account] = allowed;
    }

    function canTransact(address account) external view returns (bool ok) {
        return canByAccount[account];
    }

    function canTransfer(address, address, uint256) external pure returns (bool ok) {
        return true;
    }

    function transferStatus(address, address, uint256) external pure returns (bool ok, uint8 code) {
        return (true, 0);
    }
}

contract OnRampShareTokenMock is IAgriModulesV1 {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    uint8 internal immutable _decimals;
    address public roleManager;
    bytes32 public campaignId;

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
        address treasury_
    ) {
        roleManager = roleManager_;
        campaignId = campaignId_;
        _decimals = decimals_;
        compliance = compliance_;
        disaster = disaster_;
        treasuryAddr = treasury_;
        _gas = UAgriTypes.ViewGasLimits({
            complianceGas: 100_000,
            disasterGas: 100_000,
            freezeGas: 100_000,
            custodyGas: 100_000,
            extraGas: 100_000
        });
    }

    function decimals() external view returns (uint8) {
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

contract OnRampSponsoredDepositTest is Test {
    RoleManager internal rm;
    OnRampERC20Mock internal usdc;
    OnRampTreasuryMock internal treasury;
    OnRampRegistryMock internal registry;
    OnRampDisasterMock internal disaster;
    OnRampComplianceMock internal compliance;
    OnRampShareTokenMock internal share;
    FundingManager internal funding;

    bytes32 internal campaignId = keccak256("onramp-campaign");

    address internal onRampOperator = makeAddr("onramp-operator");
    address internal payer = makeAddr("onramp-collector");
    address internal beneficiary = makeAddr("investor");
    address internal outsider = makeAddr("outsider");
    address internal feeReceiver = makeAddr("fee-receiver");

    function setUp() public {
        rm = new RoleManager(address(this));
        usdc = new OnRampERC20Mock(6);
        treasury = new OnRampTreasuryMock(address(usdc));
        registry = new OnRampRegistryMock(campaignId, address(usdc), type(uint256).max, UAgriTypes.CampaignState.FUNDING);
        disaster = new OnRampDisasterMock();
        compliance = new OnRampComplianceMock();
        share = new OnRampShareTokenMock(
            address(rm),
            campaignId,
            6,
            address(compliance),
            address(disaster),
            address(treasury)
        );

        funding = new FundingManager(
            address(rm),
            campaignId,
            address(share),
            address(registry),
            address(0),
            0,
            0,
            address(0),
            false,
            false,
            false
        );

        rm.grantRole(UAgriRoles.ONRAMP_OPERATOR_ROLE, onRampOperator);
        compliance.setCanTransact(beneficiary, true);
    }

    function testSponsoredDeposit_mintsToBeneficiary_chargesPayer_andMarksRef() public {
        _mintAndApprovePayer(100_000);
        bytes32 ref = keccak256("sponsored-1");

        vm.prank(onRampOperator);
        uint256 sharesOut = funding.settleDepositExactAssetsFrom(payer, beneficiary, 100_000, 0, 0, ref);

        assertEq(sharesOut, 100_000);
        assertEq(share.balanceOf(beneficiary), 100_000);
        assertEq(usdc.balanceOf(payer), 0);
        assertEq(usdc.balanceOf(address(treasury)), 100_000);
        assertTrue(funding.usedSponsoredDepositRef(ref));
    }

    function testSponsoredDeposit_revertsOnRefReplay() public {
        _mintAndApprovePayer(200_000);
        bytes32 ref = keccak256("sponsored-replay");

        vm.prank(onRampOperator);
        funding.settleDepositExactAssetsFrom(payer, beneficiary, 100_000, 0, 0, ref);

        vm.prank(onRampOperator);
        vm.expectRevert(UAgriErrors.UAgri__Replay.selector);
        funding.settleDepositExactAssetsFrom(payer, beneficiary, 100_000, 0, 0, ref);
    }

    function testSponsoredDeposit_revertsIfUnauthorizedCaller() public {
        _mintAndApprovePayer(100_000);
        bytes32 ref = keccak256("sponsored-unauthorized");

        vm.prank(outsider);
        vm.expectRevert(UAgriErrors.UAgri__Unauthorized.selector);
        funding.settleDepositExactAssetsFrom(payer, beneficiary, 100_000, 0, 0, ref);
    }

    function testSponsoredDeposit_revertsIfRefIsZero() public {
        _mintAndApprovePayer(100_000);

        vm.prank(onRampOperator);
        vm.expectRevert(FundingManager.FundingManager__InvalidRef.selector);
        funding.settleDepositExactAssetsFrom(payer, beneficiary, 100_000, 0, 0, bytes32(0));
    }

    function testSponsoredDeposit_appliesComplianceToBeneficiary() public {
        _mintAndApprovePayer(200_000);

        compliance.setCanTransact(payer, false);
        compliance.setCanTransact(beneficiary, true);

        vm.prank(onRampOperator);
        funding.settleDepositExactAssetsFrom(payer, beneficiary, 100_000, 0, 0, keccak256("beneficiary-only"));
        assertEq(share.balanceOf(beneficiary), 100_000);

        compliance.setCanTransact(payer, true);
        compliance.setCanTransact(beneficiary, false);

        vm.prank(onRampOperator);
        vm.expectRevert(UAgriErrors.UAgri__ComplianceDenied.selector);
        funding.settleDepositExactAssetsFrom(payer, beneficiary, 100_000, 0, 0, keccak256("beneficiary-blocked"));
    }

    function testSponsoredDeposit_respectsCapAndFees() public {
        funding.setFees(1_000, 0, feeReceiver);
        registry.setFundingCap(100_000);

        _mintAndApprovePayer(120_000);

        vm.prank(onRampOperator);
        uint256 sharesOut = funding.settleDepositExactAssetsFrom(payer, beneficiary, 60_000, 0, 0, keccak256("cap-1"));

        assertEq(sharesOut, 54_000);
        assertEq(share.balanceOf(beneficiary), 54_000);
        assertEq(usdc.balanceOf(address(treasury)), 54_000);
        assertEq(usdc.balanceOf(feeReceiver), 6_000);

        bytes32 ref2 = keccak256("cap-2");
        vm.prank(onRampOperator);
        vm.expectRevert(
            abi.encodeWithSelector(FundingManager.FundingManager__CapExceeded.selector, uint256(100_000), uint256(108_000))
        );
        funding.settleDepositExactAssetsFrom(payer, beneficiary, 60_000, 0, 0, ref2);
        assertFalse(funding.usedSponsoredDepositRef(ref2));
    }

    function _mintAndApprovePayer(uint256 amount) internal {
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(address(funding), type(uint256).max);
    }
}
