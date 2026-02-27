// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {UAgriTypes} from "src/interfaces/constants/UAgriTypes.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";
import {UAgriFlags} from "src/interfaces/constants/UAgriFlags.sol";
import {IAgriModulesV1} from "src/interfaces/v1/IAgriModulesV1.sol";
import {IAgriIdentityAttestationV1} from "src/interfaces/v1/IAgriIdentityAttestationV1.sol";

import {CampaignTemplate} from "src/factory/CampaignTemplate.sol";
import {CampaignFactory} from "src/factory/CampaignFactory.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {AgriCampaignRegistry} from "src/campaign/AgriCampaignRegistry.sol";
import {AgriShareToken} from "src/core/AgriShareToken.sol";
import {CampaignTreasury} from "src/campaign/CampaignTreasury.sol";
import {FundingManager} from "src/campaign/FundingManager.sol";
import {SettlementQueue} from "src/campaign/SettlementQueue.sol";

import {IdentityAttestation} from "src/compliance/IdentityAttestation.sol";
import {ComplianceModuleV1} from "src/compliance/ComplianceModuleV1.sol";

import {DisasterModule} from "src/disaster/DisasterModule.sol";
import {InsurancePool} from "src/disaster/InsurancePool.sol";

import {FreezeManager} from "src/control/FreezeManager.sol";
import {ForcedTransferController} from "src/control/ForcedTransferController.sol";
import {BridgeModule} from "src/bridge/BridgeModule.sol";

import {TraceabilityRegistry} from "src/trace/TraceabilityRegistry.sol";
import {DocumentRegistry} from "src/trace/DocumentRegistry.sol";
import {BatchMerkleAnchor} from "src/trace/BatchMerkleAnchor.sol";

import {SnapshotModule} from "src/distribution/SnapshotModule.sol";
import {YieldAccumulator} from "src/distribution/YieldAccumulator.sol";
import {DeliveryModule} from "src/extensions/delivery/DeliveryModule.sol";
import {MarketplaceModule} from "src/extensions/marketplace/MarketplaceModule.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
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

        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }

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

contract DummyTreasury {
    address public settlementAsset;

    constructor(address asset) {
        settlementAsset = asset;
    }
}

contract DummyShareToken {
    address private _roleManager;
    bytes32 private _campaignId;
    address private _treasury;
    uint8 private _decimals;

    constructor(address rm, bytes32 cid, address treasury_, uint8 decimals_) {
        _roleManager = rm;
        _campaignId = cid;
        _treasury = treasury_;
        _decimals = decimals_;
    }

    function roleManager() external view returns (address) {
        return _roleManager;
    }

    function campaignId() external view returns (bytes32) {
        return _campaignId;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function totalSupply() external pure returns (uint256) {
        return 1;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    function complianceModule() external pure returns (address) { return address(0); }
    function disasterModule() external pure returns (address) { return address(0); }
    function freezeModule() external pure returns (address) { return address(0); }
    function custodyModule() external pure returns (address) { return address(0); }
    function traceModule() external pure returns (address) { return address(0); }
    function documentRegistry() external pure returns (address) { return address(0); }
    function settlementQueue() external pure returns (address) { return address(0); }
    function distribution() external pure returns (address) { return address(0); }
    function bridgeModule() external pure returns (address) { return address(0); }
    function marketplaceModule() external pure returns (address) { return address(0); }
    function deliveryModule() external pure returns (address) { return address(0); }
    function insuranceModule() external pure returns (address) { return address(0); }

    function treasury() external view returns (address) {
        return _treasury;
    }
}

contract SystemFlowTest is Test {
    CampaignTemplate internal template;
    CampaignFactory internal factory;
    CampaignFactory.CampaignStack internal stack;

    AgriShareToken internal shareToken;
    AgriCampaignRegistry internal registry;
    CampaignTreasury internal treasury;
    FundingManager internal funding;
    SettlementQueue internal queue;
    IdentityAttestation internal identity;
    ComplianceModuleV1 internal compliance;
    TraceabilityRegistry internal trace;
    DocumentRegistry internal documents;
    BatchMerkleAnchor internal batchAnchor;
    SnapshotModule internal snapshot;
    YieldAccumulator internal distribution;
    DisasterModule internal disaster;
    InsurancePool internal insurance;
    FreezeManager internal freeze;
    ForcedTransferController internal forcedController;
    RoleManager internal roleManager;

    MockERC20 internal settlement;
    MockERC20 internal reward;

    bytes32 internal campaignId;
    bytes32 internal plotRef;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    function setUp() public {
        settlement = new MockERC20("Settlement", "SET", 6);
        reward = settlement;

        (template, factory) = _deployFactory(address(this));

        campaignId = keccak256("uAgri:test:campaign");
        plotRef = keccak256("uAgri:test:plot");

        CampaignFactory.CampaignConfig memory cfg = _buildCampaignConfig();
        CampaignFactory.RolesConfig memory roles = _buildRoles();

        stack = factory.createCampaign(cfg, roles);

        shareToken = AgriShareToken(stack.shareToken);
        registry = AgriCampaignRegistry(stack.registry);
        treasury = CampaignTreasury(stack.treasury);
        funding = FundingManager(stack.fundingManager);
        queue = SettlementQueue(stack.settlementQueue);
        identity = IdentityAttestation(stack.identityAttestation);
        compliance = ComplianceModuleV1(stack.compliance);
        trace = TraceabilityRegistry(stack.trace);
        documents = DocumentRegistry(stack.documentRegistry);
        batchAnchor = BatchMerkleAnchor(stack.batchAnchor);
        snapshot = SnapshotModule(stack.snapshot);
        distribution = YieldAccumulator(stack.distribution);
        disaster = DisasterModule(stack.disaster);
        insurance = InsurancePool(stack.insurance);
        freeze = FreezeManager(stack.freezeModule);
        forcedController = ForcedTransferController(stack.forcedTransferController);
        roleManager = RoleManager(stack.roleManager);

        _openDefaultComplianceProfile();

        snapshot.setSnapshotter(address(this), true);
        shareToken.setDistributionHooksConfig(true, false, 200_000);
    }

    function testFactoryStackCreatedWithAllModules() public view {
        assertEq(factory.stacks(campaignId).shareToken, stack.shareToken);

        assertTrue(stack.roleManager != address(0));
        assertTrue(stack.registry != address(0));
        assertTrue(stack.shareToken != address(0));
        assertTrue(stack.treasury != address(0));
        assertTrue(stack.fundingManager != address(0));
        assertTrue(stack.settlementQueue != address(0));

        assertTrue(stack.identityAttestation != address(0));
        assertTrue(stack.compliance != address(0));
        assertTrue(stack.disaster != address(0));
        assertTrue(stack.freezeModule != address(0));
        assertTrue(stack.forcedTransferController != address(0));

        assertTrue(stack.trace != address(0));
        assertTrue(stack.documentRegistry != address(0));
        assertTrue(stack.batchAnchor != address(0));

        assertTrue(stack.snapshot != address(0));
        assertTrue(stack.distribution != address(0));
        assertTrue(stack.insurance != address(0));
    }

    function testFactoryRejectsDistributionRewardTokenMismatch() public {
        CampaignFactory.CampaignConfig memory cfg = _buildCampaignConfig();
        cfg.campaign.campaignId = keccak256("uAgri:test:campaign:mismatch");
        cfg.rewardToken = address(new MockERC20("Other", "OTH", 6));

        vm.expectRevert(CampaignFactory.CampaignFactory__InvalidRewardToken.selector);
        factory.createCampaign(cfg, _buildRoles());
    }

    function testFundingDistributionAndRedeemFlow() public {
        _seedShares(alice, 500_000_000);

        uint256 aliceShares = shareToken.balanceOf(alice);
        assertGt(aliceShares, 0);

        settlement.mint(address(treasury), 200_000_000);

        uint64 liquidationId = uint64(distribution.nextLiquidationId());
        distribution.notifyReward(200_000_000, liquidationId, keccak256("reward-report-1"));

        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidLiquidationId.selector);
        distribution.notifyReward(1, liquidationId, keccak256("reward-report-replay"));

        vm.expectRevert(YieldAccumulator.YieldAccumulator__InvalidLiquidationId.selector);
        distribution.notifyReward(1, liquidationId + 2, keccak256("reward-report-gap"));

        vm.prank(alice);
        uint256 claimed = distribution.claim();
        assertGt(claimed, 0);
        assertEq(reward.balanceOf(alice), claimed);

        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, aliceShares / 4));
        assertGt(shareToken.balanceOf(bob), 0);

        vm.prank(alice);
        uint256 assetsOut = funding.redeemInstant(aliceShares / 4, 0, 0, keccak256("redeem"));
        assertGt(assetsOut, 0);
        assertGt(settlement.balanceOf(alice), 0);
    }

    function testQueueRequestAndBatchProcess() public {
        settlement.mint(alice, 400_000_000);

        vm.startPrank(alice);
        settlement.approve(address(funding), type(uint256).max);
        uint256 id = queue.requestDeposit(400_000_000, 0, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        queue.batchProcess(ids, 1, keccak256("report"));

        assertGt(shareToken.balanceOf(alice), 0);
    }

    function testTraceDocumentsAndAnchors() public {
        bytes32 lotId = keccak256("lot-1");
        bytes32 traceDataHash = keccak256("trace-data");

        trace.emitTrace(
            campaignId,
            plotRef,
            lotId,
            1,
            traceDataHash,
            uint64(block.timestamp),
            uint64(block.timestamp + 1),
            "ipfs://trace"
        );

        bytes32 traceRoot = keccak256("trace-root");
        trace.anchorRoot(campaignId, 1, traceRoot, uint64(block.timestamp), uint64(block.timestamp + 1));
        assertTrue(trace.isAnchored(campaignId, 1, traceRoot, uint64(block.timestamp), uint64(block.timestamp + 1)));

        bytes32 docHash = keccak256("doc-hash");
        documents.registerDoc(
            1,
            docHash,
            uint64(block.timestamp),
            campaignId,
            plotRef,
            lotId,
            "ipfs://doc"
        );

        assertEq(documents.latestVersion(1, campaignId, plotRef, lotId), 1);
        assertEq(documents.latestDocHash(1, campaignId, plotRef, lotId), docHash);

        bytes32 batchRoot = keccak256("batch-root");
        batchAnchor.anchorRoot(campaignId, 7, batchRoot, uint64(block.timestamp), uint64(block.timestamp + 2));
        assertTrue(batchAnchor.isAnchored(campaignId, 7, batchRoot, uint64(block.timestamp), uint64(block.timestamp + 2)));
    }

    function testDisasterInsuranceCompensationFlow() public {
        _seedShares(alice, 600_000_000);

        snapshot.snapshotEpoch(10, keccak256("epoch-10"));

        disaster.declareDisaster(
            campaignId,
            keccak256("HAZARD"),
            2,
            keccak256("disaster-reason"),
            0
        );

        settlement.mint(address(this), 300_000_000);
        settlement.approve(address(insurance), 300_000_000);
        insurance.fund(300_000_000);

        insurance.notifyCompensation(200_000_000, 10, keccak256("comp-pack"));

        uint256 before = settlement.balanceOf(alice);

        vm.prank(alice);
        uint256 paid = insurance.claimCompensation();

        assertGt(paid, 0);
        assertEq(settlement.balanceOf(alice), before + paid);
    }

    function testFreezeAndForcedTransferFlow() public {
        _seedShares(alice, 700_000_000);

        uint256 bal = shareToken.balanceOf(alice);
        assertGt(bal, 10);

        freeze.setFrozenTokens(alice, bal - 1);

        vm.startPrank(alice);
        vm.expectRevert();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        shareToken.transfer(bob, bal / 2);
        vm.stopPrank();

        shareToken.forcedTransfer(alice, bob, bal / 2);

        assertEq(shareToken.balanceOf(bob), bal / 2);
        assertEq(shareToken.balanceOf(alice), bal - (bal / 2));
    }

    function testRoleManagerAdminTransferFlow() public {
        address newAdmin = makeAddr("new-admin");

        factory.beginRoleManagerAdminHandoff(campaignId, newAdmin);

        vm.warp(block.timestamp + roleManager.defaultAdminTransferDelay());

        vm.prank(newAdmin);
        roleManager.acceptDefaultAdminTransfer();

        assertTrue(roleManager.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, newAdmin));
    }

    function testCampaignRegistryLifecycleAndGovernanceEdits() public {
        bytes32 docsRoot = keccak256("docs-root-v2");
        registry.setDocsRootHash(campaignId, docsRoot);
        assertEq(registry.getCampaign(campaignId).docsRootHash, docsRoot);

        registry.setFundingCap(campaignId, 2_000_000_000);
        registry.setTiming(campaignId, uint64(block.timestamp), uint64(block.timestamp + 2 days));
        registry.setJurisdictionProfile(campaignId, keccak256("profile-v2"));

        registry.setCampaignState(campaignId, UAgriTypes.CampaignState.ACTIVE);

        vm.expectRevert();
        registry.setFundingCap(campaignId, 1);

        registry.setCampaignState(campaignId, UAgriTypes.CampaignState.HARVESTED);
        registry.setCampaignState(campaignId, UAgriTypes.CampaignState.SETTLED);
        registry.setCampaignState(campaignId, UAgriTypes.CampaignState.CLOSED);

        vm.expectRevert();
        registry.setCampaignState(campaignId, UAgriTypes.CampaignState.ACTIVE);
    }

    function testSettlementQueueModeAndCancellationPaths() public {
        queue.setDepositExactSharesMode(true);

        settlement.mint(alice, 500_000_000);

        vm.startPrank(alice);
        settlement.approve(address(funding), type(uint256).max);
        uint256 exactSharesRequest = queue.requestDeposit(100_000_000, 120_000_000, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        uint256[] memory ids = new uint256[](1);
        ids[0] = exactSharesRequest;
        queue.batchProcess(ids, 2, keccak256("exact-shares"));

        assertGt(shareToken.balanceOf(alice), 0);

        vm.startPrank(alice);
        uint256 redeemRequest = queue.requestRedeem(shareToken.balanceOf(alice) / 4, 0, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert();
        queue.cancel(redeemRequest);

        vm.prank(alice);
        queue.cancel(redeemRequest);

        UAgriTypes.Request memory r = queue.getRequest(redeemRequest);
        assertEq(uint256(r.status), uint256(UAgriTypes.RequestStatus.Cancelled));
    }

    function testFundingManagerConfigAndCapGuards() public {
        funding.setFees(100, 50, address(this));
        funding.setPolicyToggles(true, true, false);

        (uint256 sharesOut, uint256 feeAssets) = funding.previewDepositExactAssets(100_000_000);
        assertGt(sharesOut, 0);
        assertGt(feeAssets, 0);

        registry.setFundingCap(campaignId, 10_000_000);

        settlement.mint(alice, 20_000_000);
        vm.startPrank(alice);
        settlement.approve(address(funding), type(uint256).max);
        vm.expectRevert();
        funding.depositInstant(20_000_000, 0, uint64(block.timestamp + 1 days), keccak256("cap-check"));
        vm.stopPrank();
    }

    function testTreasuryAuthAndComplianceOnPay() public {
        settlement.mint(address(treasury), 500_000_000);

        vm.prank(bob);
        vm.expectRevert();
        treasury.pay(bob, 1, keccak256("bad-auth"));

        treasury.setSpender(carol, true);
        assertTrue(treasury.isSpender(carol));

        treasury.pay(alice, 100_000_000, keccak256("ok-pay"));
        assertEq(settlement.balanceOf(alice), 100_000_000);

        treasury.setEnforceComplianceOnPay(true);
        compliance.setSanctioned(bob, true);

        vm.expectRevert();
        treasury.pay(bob, 1, keccak256("blocked"));

        compliance.setSanctioned(bob, false);

        treasury.noteInflow(7, 55, keccak256("inflow"));
        assertEq(treasury.inflowByEpoch(7), 55);

        vm.prank(bob);
        vm.expectRevert();
        treasury.noteInflow(8, 1, keccak256("bad-inflow"));

        treasury.recoverERC20(address(settlement), dave, 10_000_000);
        assertEq(settlement.balanceOf(dave), 10_000_000);
    }

    function testDisasterModuleConfirmAndExpiryPaths() public {
        vm.prank(bob);
        vm.expectRevert();
        disaster.declareDisaster(campaignId, keccak256("HZ-UNAUTH"), 2, keccak256("r"), 1);

        disaster.declareDisaster(campaignId, keccak256("HARD"), 3, keccak256("ttl"), 60);
        assertFalse(disaster.isHardFrozen(campaignId));
        assertTrue(disaster.isRestricted(campaignId));

        disaster.confirmDisaster(campaignId, 0, 3);
        assertTrue(disaster.isHardFrozen(campaignId));

        disaster.setManualPauseFlags(campaignId, UAgriFlags.PAUSE_ORACLES);
        uint256 flags = disaster.campaignFlags(campaignId);
        assertTrue((flags & UAgriFlags.PAUSE_TRANSFERS) != 0);
        assertTrue((flags & UAgriFlags.PAUSE_ORACLES) != 0);

        disaster.clearDisaster(campaignId);
        assertEq(disaster.campaignFlags(campaignId), 0);

        disaster.declareDisaster(campaignId, keccak256("RESTRICTED"), 2, keccak256("exp"), 1);
        vm.warp(block.timestamp + 2);
        assertEq(disaster.campaignFlags(campaignId), 0);
        assertFalse(disaster.isRestricted(campaignId));
        assertFalse(disaster.isHardFrozen(campaignId));
    }

    function testIdentityAndComplianceBranchMatrix() public {
        uint32 providerId = 77;
        uint256 providerPk = 0xB0B;
        address provider = vm.addr(providerPk);

        identity.setProvider(providerId, provider, true);

        ComplianceModuleV1.JurisdictionProfile memory strict = ComplianceModuleV1.JurisdictionProfile({
            enabled: true,
            requireIdentity: true,
            allowNoExpiry: false,
            enforceLockupOnTransfer: true,
            sameJurisdictionOnly: false,
            minTier: 2,
            maxTier: 3,
            requiredFlags: 1,
            forbiddenFlags: 2,
            minTtlSeconds: 1 days,
            maxTransfer: 1_000
        });
        compliance.setProfile(0, strict);

        IAgriIdentityAttestationV1.Payload memory pa = IAgriIdentityAttestationV1.Payload({
            jurisdiction: 34,
            tier: 2,
            flags: 1,
            expiry: uint64(block.timestamp + 3 days),
            lockupUntil: uint64(block.timestamp + 1 days),
            providerId: providerId
        });
        IAgriIdentityAttestationV1.Payload memory pb = IAgriIdentityAttestationV1.Payload({
            jurisdiction: 34,
            tier: 2,
            flags: 1,
            expiry: uint64(block.timestamp + 3 days),
            lockupUntil: 0,
            providerId: providerId
        });

        _registerIdentity(alice, pa, uint64(block.timestamp + 1 days), providerPk);
        _registerIdentity(bob, pb, uint64(block.timestamp + 1 days), providerPk);

        (bool ok, uint8 code) = compliance.transferStatus(alice, bob, 500);
        assertFalse(ok);
        assertEq(code, 40);

        vm.warp(block.timestamp + 1 days + 1);

        (ok, code) = compliance.transferStatus(alice, bob, 1_500);
        assertFalse(ok);
        assertEq(code, 42);

        (ok, code) = compliance.transferStatus(alice, bob, 500);
        assertTrue(ok);
        assertEq(code, 0);

        compliance.setPairBlocked(34, 34, true);
        (ok, code) = compliance.transferStatus(alice, bob, 500);
        assertFalse(ok);
        assertEq(code, 41);

        compliance.setPairBlocked(34, 34, false);
        compliance.setSanctioned(bob, true);

        (ok, code) = compliance.transferStatus(alice, bob, 500);
        assertFalse(ok);
        assertEq(code, 11);

        compliance.setSanctioned(bob, false);
        compliance.setDenylisted(alice, true);

        (ok, code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 10);

        compliance.setDenylisted(alice, false);
        compliance.setPaused(true);

        (ok, code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 1);

        compliance.setPaused(false);

        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        compliance.setExemptBatch(accounts, true);

        (ok, code) = compliance.transferStatus(alice, bob, 100_000);
        assertTrue(ok);
        assertEq(code, 0);
    }

    function testBridgeModuleRoundTripAndReplayProtection() public {
        _becomeRoleManagerAdmin();

        BridgeModule bridge = new BridgeModule(address(roleManager), address(shareToken), campaignId);
        roleManager.grantRole(UAgriRoles.FARM_OPERATOR_ROLE, address(bridge));

        uint256 bridgeSignerPk = 0xC0FFEE;
        address bridgeSigner = vm.addr(bridgeSignerPk);
        roleManager.grantRole(UAgriRoles.BRIDGE_OPERATOR_ROLE, bridgeSigner);

        _seedShares(alice, 300_000_000);
        uint256 amount = shareToken.balanceOf(alice) / 3;

        vm.prank(alice);
        uint256 nonceOut = bridge.bridgeOut(campaignId, amount, 777, alice);
        assertEq(nonceOut, 1);

        bytes32 digest1 = bridge.hashBridgeIn(campaignId, amount, 555, bob, 1);
        bytes memory sig1 = _sig(bridgeSignerPk, digest1);

        bridge.bridgeIn(campaignId, amount, 555, bob, 1, sig1);
        assertGt(shareToken.balanceOf(bob), 0);

        vm.expectRevert();
        bridge.bridgeIn(campaignId, amount, 555, bob, 1, sig1);

        bytes32 digest2 = bridge.hashBridgeIn(campaignId, amount, 556, bob, 2);
        bytes memory sig2 = _sig(bridgeSignerPk, digest2);
        bytes memory proof = bytes.concat(bytes20(bridgeSigner), sig2);
        bridge.bridgeIn(campaignId, amount, 556, bob, 2, proof);
    }

    function testDeliveryAndMarketplaceFlows() public {
        _becomeRoleManagerAdmin();

        DeliveryModule delivery = new DeliveryModule(address(roleManager), address(shareToken));
        roleManager.grantRole(UAgriRoles.FARM_OPERATOR_ROLE, address(delivery));

        _seedShares(alice, 200_000_000);
        uint256 shares = shareToken.balanceOf(alice) / 5;

        vm.prank(alice);
        delivery.redeemToReceipt(shares, 1, keccak256("lot-1"), keccak256("terms-1"));

        vm.prank(alice);
        vm.expectRevert();
        delivery.redeemToReceipt(1, 1, keccak256("lot-1"), keccak256("terms-1"));

        compliance.setSanctioned(alice, true);
        vm.prank(alice);
        vm.expectRevert();
        delivery.redeemToReceipt(1, 2, keccak256("lot-2"), keccak256("terms-2"));
        compliance.setSanctioned(alice, false);

        vm.prank(bob);
        vm.expectRevert();
        delivery.setToken(address(shareToken));

        delivery.setToken(address(shareToken));

        MarketplaceModule market = new MarketplaceModule(address(roleManager), carol, 500);

        uint256 sellAmount = 40_000;
        vm.startPrank(alice);
        shareToken.approve(address(market), sellAmount);
        uint256 listingId = market.list(address(shareToken), sellAmount, address(settlement), 2);
        vm.stopPrank();

        settlement.mint(bob, 1_000_000_000);
        vm.prank(bob);
        settlement.approve(address(market), type(uint256).max);

        vm.prank(bob);
        market.buy(listingId, sellAmount / 2);

        (address seller, , , uint256 remaining, ) = market.listings(listingId);
        assertEq(seller, alice);
        assertEq(remaining, sellAmount / 2);

        vm.prank(bob);
        vm.expectRevert();
        market.setFee(dave, 100);

        market.setFee(dave, 100);
        vm.prank(alice);
        market.cancel(listingId);

        (seller, , , remaining, ) = market.listings(listingId);
        assertEq(seller, address(0));
        assertEq(remaining, 0);
    }

    function testForcedTransferControllerPreviewAndDisable() public {
        _seedShares(alice, 150_000_000);
        uint256 bal = shareToken.balanceOf(alice);

        freeze.setFrozenTokens(alice, bal - 10);

        (uint256 frozenBefore, uint256 frozenAfter) = forcedController.previewFrozenAfter(alice, bal / 2, bal);
        assertEq(frozenBefore, bal - 10);
        assertEq(frozenAfter, bal - (bal / 2));

        vm.prank(bob);
        vm.expectRevert();
        forcedController.setEnabled(false);

        forcedController.setEnabled(false);

        vm.expectRevert();
        shareToken.forcedTransfer(alice, bob, bal / 4);

        forcedController.setEnabled(true);
        shareToken.forcedTransfer(alice, bob, bal / 4);
        assertGt(shareToken.balanceOf(bob), 0);
    }

    function testDistributionStrictHooksAndRecovery() public {
        vm.expectRevert();
        distribution.setRequireHooks(true);

        _seedShares(alice, 100_000_000);
        distribution.setRequireHooks(true);

        settlement.mint(address(treasury), 50_000_000);
        uint64 liquidationId = uint64(distribution.nextLiquidationId());
        distribution.notifyReward(50_000_000, liquidationId, keccak256("r99"));

        distribution.setEnforceComplianceOnClaim(true);
        compliance.setSanctioned(alice, true);

        vm.prank(alice);
        vm.expectRevert();
        distribution.claim();

        compliance.setSanctioned(alice, false);

        vm.prank(alice);
        uint256 paid = distribution.claim();
        assertGt(paid, 0);

        reward.mint(address(distribution), 1_000);
        distribution.recoverERC20(address(reward), dave, 1_000);
        assertEq(reward.balanceOf(dave), 1_000);
    }

    function testSnapshotCheckpointQueriesAndGuards() public {
        _seedShares(alice, 120_000_000);

        uint64 sid = snapshot.snapshotEpoch(55, keccak256("snap-55"));
        assertEq(sid, 1);

        uint256 aliceBefore = shareToken.balanceOf(alice);
        uint256 supplyBefore = shareToken.totalSupply();

        vm.prank(address(shareToken));
        snapshot.onMint(alice, 1);

        vm.prank(address(shareToken));
        snapshot.onTransfer(alice, bob, 1);

        uint256 amount = aliceBefore / 3;
        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, amount));

        uint256 balAlice = snapshot.balanceOfAtEpoch(alice, 55);
        uint256 balBob = snapshot.balanceOfAtEpoch(bob, 55);
        uint256 supplyAt = snapshot.totalSupplyAtEpoch(55);

        assertEq(balAlice, aliceBefore);
        assertEq(balBob, 0);
        assertEq(supplyAt, supplyBefore);

        vm.expectRevert();
        snapshot.snapshotEpoch(55, bytes32(0));

        vm.expectRevert();
        snapshot.balanceOfAt(alice, 2);

        vm.expectRevert();
        snapshot.onTransfer(alice, bob, 1);
    }

    function _sig(uint256 signerPk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _becomeRoleManagerAdmin() internal {
        if (roleManager.hasRole(UAgriRoles.DEFAULT_ADMIN_ROLE, address(this))) {
            return;
        }

        factory.beginRoleManagerAdminHandoff(campaignId, address(this));
        roleManager.acceptDefaultAdminTransfer();
    }

    function _registerIdentity(
        address account,
        IAgriIdentityAttestationV1.Payload memory payload,
        uint64 deadline,
        uint256 signerPk
    ) internal {
        bytes32 digest = identity.hashRegister(account, payload, deadline);
        bytes memory sig = _sig(signerPk, digest);
        identity.register(account, payload, deadline, sig);
    }

    function _seedShares(address account, uint256 assets) internal {
        settlement.mint(account, assets);

        vm.startPrank(account);
        settlement.approve(address(funding), type(uint256).max);
        funding.depositInstant(assets, 0, 0, keccak256("seed"));
        vm.stopPrank();
    }

    function _openDefaultComplianceProfile() internal {
        ComplianceModuleV1.JurisdictionProfile memory p = ComplianceModuleV1.JurisdictionProfile({
            enabled: true,
            requireIdentity: false,
            allowNoExpiry: true,
            enforceLockupOnTransfer: false,
            sameJurisdictionOnly: false,
            minTier: 0,
            maxTier: 0,
            requiredFlags: 0,
            forbiddenFlags: 0,
            minTtlSeconds: 0,
            maxTransfer: 0
        });

        compliance.setProfile(0, p);
    }

    function _buildCampaignConfig() internal view returns (CampaignFactory.CampaignConfig memory cfg) {
        UAgriTypes.Campaign memory c = UAgriTypes.Campaign({
            campaignId: campaignId,
            plotRef: plotRef,
            subPlotId: bytes32(uint256(1)),
            areaBps: 10_000,
            startTs: 0,
            endTs: 0,
            settlementAsset: address(settlement),
            fundingCap: 100_000_000_000,
            docsRootHash: bytes32(0),
            jurisdictionProfile: bytes32(0),
            state: UAgriTypes.CampaignState.FUNDING
        });

        cfg = CampaignFactory.CampaignConfig({
            campaign: c,
            name: "uAgri Test",
            symbol: "UAT",
            decimals: 18,
            enforceComplianceOnPay: false,
            depositFeeBps: 0,
            redeemFeeBps: 0,
            feeRecipient: address(0),
            allowDepositsWhenActive: true,
            allowRedeemsDuringFunding: true,
            enforceCustodyFreshOnRedeem: false,
            depositExactSharesMode: false,
            enableForcedTransfers: true,
            enableCustodyOracle: false,
            enableTrace: true,
            enableDocuments: true,
            enableBatchAnchor: true,
            enableDistribution: true,
            rewardToken: address(reward),
            enforceComplianceOnClaim: false,
            enableInsurance: true,
            viewGas: UAgriTypes.ViewGasLimits({
                complianceGas: 0,
                disasterGas: 0,
                freezeGas: 0,
                custodyGas: 0,
                extraGas: 0
            })
        });
    }

    function _buildRoles() internal view returns (CampaignFactory.RolesConfig memory roles) {
        roles = CampaignFactory.RolesConfig({
            governance: address(this),
            guardian: address(this),
            treasuryAdmin: address(this),
            complianceOfficer: address(this),
            farmOperator: address(this),
            regulatorEnforcer: address(this),
            disasterAdmin: address(this),
            oracleUpdater: address(this),
            custodyAttester: address(this),
            insuranceAdmin: address(this),
            onRampOperator: address(this),
            payoutOperator: address(this),
            rewardNotifier: address(this)
        });
    }

    function _deployFactory(address admin) internal returns (CampaignTemplate tpl, CampaignFactory fac) {
        bytes32 dummyCampaignId = keccak256("uAgri:impl");
        DummyTreasury dummyTreasury = new DummyTreasury(address(settlement));
        DummyShareToken dummyShareToken = new DummyShareToken(address(0xBEEF), dummyCampaignId, address(dummyTreasury), 18);

        address dummyToken = address(dummyShareToken);
        address dummyErc20 = address(settlement);

        UAgriTypes.ViewGasLimits memory defaultGas = UAgriTypes.ViewGasLimits({
            complianceGas: 100_000,
            disasterGas: 80_000,
            freezeGas: 80_000,
            custodyGas: 80_000,
            extraGas: 40_000
        });

        CampaignTemplate.TemplateV1 memory t;

        address rm = address(new RoleManager(admin));

        // align dummy share token with the role manager used by implementation constructors
        dummyShareToken = new DummyShareToken(rm, dummyCampaignId, address(dummyTreasury), 18);
        dummyToken = address(dummyShareToken);
        t.roleManager = rm;

        t.campaignRegistry = address(new AgriCampaignRegistry(rm));
        t.freezeManager = address(new FreezeManager(rm, address(0)));
        t.forcedTransferController = address(new ForcedTransferController(rm, t.freezeManager, address(0), false));
        t.disasterModule = address(new DisasterModule(rm));
        t.identityAttestation = address(new IdentityAttestation(rm));
        t.complianceModule = address(new ComplianceModuleV1(rm, t.identityAttestation));
        t.snapshotModule = address(new SnapshotModule(rm, dummyToken));
        t.yieldAccumulator = address(new YieldAccumulator(rm, dummyToken, dummyErc20, false));
        t.insurancePool = address(new InsurancePool(rm, dummyCampaignId, dummyErc20, t.snapshotModule, t.disasterModule));
        t.traceRegistry = address(new TraceabilityRegistry(rm));
        t.documentRegistry = address(new DocumentRegistry(rm));
        t.batchMerkleAnchor = address(new BatchMerkleAnchor(rm));
        t.treasury = address(new CampaignTreasury(rm, dummyCampaignId, dummyToken, dummyErc20, address(0), false));
        t.fundingManager = address(
            new FundingManager(
                rm,
                dummyCampaignId,
                dummyToken,
                t.campaignRegistry,
                address(0),
                0,
                0,
                address(0),
                false,
                false,
                false
            )
        );
        t.settlementQueue = address(new SettlementQueue(rm, dummyCampaignId, t.fundingManager, false));

        IAgriModulesV1.ModulesV1 memory mods = IAgriModulesV1.ModulesV1({
            compliance: t.complianceModule,
            disaster: t.disasterModule,
            freezeModule: t.freezeManager,
            custody: address(0),
            trace: address(0),
            documentRegistry: address(0),
            settlementQueue: address(0),
            treasury: address(0),
            distribution: address(0),
            bridge: address(0),
            marketplace: address(0),
            delivery: address(0),
            insurance: address(0)
        });

        t.shareToken = address(
            new AgriShareToken(
                rm,
                dummyCampaignId,
                "uAgri ShareToken impl",
                "UAT-IMPL",
                18,
                mods,
                t.forcedTransferController,
                defaultGas
            )
        );

        tpl = new CampaignTemplate(admin, t, defaultGas);
        fac = new CampaignFactory(admin, address(tpl));
    }
}
