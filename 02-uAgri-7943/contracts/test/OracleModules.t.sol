// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";
import {IAgriOracleSubmitV1} from "src/interfaces/v1/IAgriOracleSubmitV1.sol";

import {CustodyOracle} from "src/oracles/CustodyOracle.sol";
import {HarvestOracle} from "src/oracles/HarvestOracle.sol";
import {SalesProceedsOracle} from "src/oracles/SalesProceedsOracle.sol";
import {DisasterEvidenceOracle} from "src/oracles/DisasterEvidenceOracle.sol";
import {ChainlinkAdapter} from "src/oracles/adapters/ChainlinkAdapter.sol";

contract Mock1271Submitter {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    bool public valid = true;

    function setValid(bool v) external {
        valid = v;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return valid ? MAGIC : bytes4(0xffffffff);
    }

    function submit(CustodyOracle oracle, IAgriOracleSubmitV1.Attestation calldata att, bytes calldata sig) external {
        oracle.submitAttestation(att, sig);
    }
}

contract MockAggregatorV3 {
    uint8 private _decimals;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(uint8 d, int256 a, uint256 u) {
        _decimals = d;
        _answer = a;
        _updatedAt = u;
    }

    function setLatest(int256 a, uint256 u) external {
        _answer = a;
        _updatedAt = u;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = 1;
        answer = _answer;
        startedAt = _updatedAt;
        updatedAt = _updatedAt;
        answeredInRound = 1;
    }
}

contract OracleModulesTest is Test {
    RoleManager internal rm;

    CustodyOracle internal custody;
    HarvestOracle internal harvest;
    SalesProceedsOracle internal sales;
    DisasterEvidenceOracle internal disaster;

    ChainlinkAdapter internal adapter;

    uint256 internal signerPk;
    address internal signer;

    bytes32 internal campaignId = keccak256("oracle-campaign");

    function setUp() public {
        vm.warp(1_000_000);

        rm = new RoleManager(address(this));

        custody = new CustodyOracle(address(rm));
        harvest = new HarvestOracle(address(rm));
        sales = new SalesProceedsOracle(address(rm));
        disaster = new DisasterEvidenceOracle(address(rm));

        adapter = new ChainlinkAdapter();

        signerPk = 0xA11CE;
        signer = vm.addr(signerPk);

        rm.grantRole(UAgriRoles.CUSTODY_ATTESTER_ROLE, signer);
        rm.grantRole(UAgriRoles.ORACLE_UPDATER_ROLE, signer);
    }

    function testCustodyOracleSubmitAndViews() public {
        IAgriOracleSubmitV1.Attestation memory att = _att(1, uint64(block.timestamp - 1), uint64(block.timestamp + 2 days));
        bytes memory sig = _signCustody(att, signer, signerPk);

        vm.prank(signer);
        custody.submitAttestation(att, sig);

        assertEq(custody.latestEpoch(campaignId), 1);
        assertEq(custody.lastCustodyEpoch(campaignId), 1);
        assertEq(custody.reportHash(campaignId, 1), att.reportHash);
        assertEq(custody.payloadHash(campaignId, 1), att.payloadHash);
        assertTrue(custody.isReportValid(campaignId, 1));
        assertEq(custody.custodyValidUntil(campaignId), att.validUntil);
        assertTrue(custody.isCustodyFresh(campaignId));

        vm.warp(block.timestamp + 3 days);
        assertFalse(custody.isReportValid(campaignId, 1));
        assertFalse(custody.isCustodyFresh(campaignId));

        assertEq(custody.nonces(signer), 1);
    }

    function testOracleValidationFailures() public {
        IAgriOracleSubmitV1.Attestation memory okAtt = _att(1, uint64(block.timestamp - 1), uint64(block.timestamp + 1 days));

        vm.prank(makeAddr("outsider"));
        vm.expectRevert();
        custody.submitAttestation(okAtt, bytes("sig"));

        IAgriOracleSubmitV1.Attestation memory badCampaign =
            _att(1, uint64(block.timestamp - 1), uint64(block.timestamp + 1 days));
        badCampaign.campaignId = bytes32(0);
        bytes memory badCampaignSig = _signCustody(badCampaign, signer, signerPk);
        vm.prank(signer);
        vm.expectRevert();
        custody.submitAttestation(badCampaign, badCampaignSig);

        IAgriOracleSubmitV1.Attestation memory badWindow =
            _att(1, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days));
        bytes memory badWindowSig = _signCustody(badWindow, signer, signerPk);
        vm.prank(signer);
        vm.expectRevert();
        custody.submitAttestation(badWindow, badWindowSig);

        IAgriOracleSubmitV1.Attestation memory stale =
            _att(1, uint64(block.timestamp - 2 days), uint64(block.timestamp - 1 days));
        bytes memory staleSig = _signCustody(stale, signer, signerPk);
        vm.prank(signer);
        vm.expectRevert();
        custody.submitAttestation(stale, staleSig);

        IAgriOracleSubmitV1.Attestation memory freshOk =
            _att(1, uint64(block.timestamp - 1), uint64(block.timestamp + 1 days));
        bytes memory sig = _signCustody(freshOk, signer, signerPk);
        vm.prank(signer);
        custody.submitAttestation(freshOk, sig);

        vm.prank(signer);
        vm.expectRevert();
        custody.submitAttestation(freshOk, sig);

        IAgriOracleSubmitV1.Attestation memory badHash = _att(2, uint64(block.timestamp - 1), uint64(block.timestamp + 1 days));
        badHash.reportHash = bytes32(0);
        bytes memory badHashSig = _signCustody(badHash, signer, signerPk);
        vm.prank(signer);
        vm.expectRevert();
        custody.submitAttestation(badHash, badHashSig);
    }

    function testOracleGovernanceSettersAndRoleSwitch() public {
        vm.prank(makeAddr("outsider"));
        vm.expectRevert();
        custody.setSubmitterRole(UAgriRoles.ORACLE_UPDATER_ROLE);

        custody.setSubmitterRole(UAgriRoles.ORACLE_UPDATER_ROLE);

        uint256 bobPk = 0xB0B;
        address bob = vm.addr(bobPk);
        rm.grantRole(UAgriRoles.ORACLE_UPDATER_ROLE, bob);

        IAgriOracleSubmitV1.Attestation memory att = _att(1, uint64(block.timestamp - 1), uint64(block.timestamp + 1 days));
        bytes memory sig = _signCustody(att, bob, bobPk);

        vm.prank(bob);
        custody.submitAttestation(att, sig);
        assertEq(custody.latestEpoch(campaignId), 1);

        vm.expectRevert();
        custody.setSubmitterRole(bytes32(0));

        RoleManager rm2 = new RoleManager(address(this));
        custody.setRoleManager(address(rm2));
        assertEq(address(custody.roleManager()), address(rm2));
    }

    function testOracleContractSignerPath1271() public {
        Mock1271Submitter submitter = new Mock1271Submitter();
        rm.grantRole(UAgriRoles.CUSTODY_ATTESTER_ROLE, address(submitter));

        IAgriOracleSubmitV1.Attestation memory att = _att(1, uint64(block.timestamp - 1), uint64(block.timestamp + 1 days));
        submitter.submit(custody, att, bytes("ok"));

        assertEq(custody.latestEpoch(campaignId), 1);

        IAgriOracleSubmitV1.Attestation memory att2 = _att(2, uint64(block.timestamp - 1), uint64(block.timestamp + 1 days));
        submitter.setValid(false);

        vm.expectRevert();
        submitter.submit(custody, att2, bytes("bad"));
    }

    function testDerivedOraclesAndInitializerGuards() public {
        assertEq(harvest.attestationTypehash(), custody.attestationTypehash());
        assertEq(sales.attestationTypehash(), custody.attestationTypehash());
        assertEq(disaster.attestationTypehash(), custody.attestationTypehash());

        vm.expectRevert();
        harvest.initialize(address(rm));

        vm.expectRevert();
        sales.initialize(address(rm));

        vm.expectRevert();
        disaster.initialize(address(rm));

        IAgriOracleSubmitV1.Attestation memory hAtt = _att(1, uint64(block.timestamp - 1), uint64(block.timestamp + 1 days));
        bytes memory hSig = _signHarvest(hAtt, signer, signerPk);

        vm.prank(signer);
        harvest.submitAttestation(hAtt, hSig);

        assertEq(harvest.latestEpoch(campaignId), 1);
    }

    function testChainlinkAdapterReadAndHashing() public {
        MockAggregatorV3 agg = new MockAggregatorV3(8, 2_000e8, block.timestamp - 100);

        (int256 answer, uint8 decimals, uint256 updatedAt) = adapter.readLatest(address(agg), 1_000);
        assertEq(answer, 2_000e8);
        assertEq(decimals, 8);
        assertEq(updatedAt, block.timestamp - 100);

        bytes32 ph = adapter.hashFeedObservation(address(agg), answer, decimals, updatedAt);
        (bytes32 ph2, int256 a2, uint8 d2, uint256 u2) = adapter.payloadHashLatest(address(agg), 1_000);

        assertEq(ph, ph2);
        assertEq(a2, answer);
        assertEq(d2, decimals);
        assertEq(u2, updatedAt);

        vm.expectRevert();
        adapter.readLatest(address(0), 0);

        agg.setLatest(0, block.timestamp);
        vm.expectRevert();
        adapter.readLatest(address(agg), 0);

        agg.setLatest(1_000e8, block.timestamp - 10_000);
        vm.expectRevert();
        adapter.readLatest(address(agg), 100);
    }

    function _att(uint64 epoch, uint64 asOf, uint64 validUntil)
        internal
        view
        returns (IAgriOracleSubmitV1.Attestation memory)
    {
        return IAgriOracleSubmitV1.Attestation({
            campaignId: campaignId,
            epoch: epoch,
            asOf: asOf,
            validUntil: validUntil,
            reportHash: keccak256(abi.encodePacked("report", epoch)),
            payloadHash: keccak256(abi.encodePacked("payload", epoch))
        });
    }

    function _signCustody(IAgriOracleSubmitV1.Attestation memory att, address who, uint256 pk)
        internal
        returns (bytes memory)
    {
        vm.prank(who);
        (bytes32 digest, ) = custody.hashAttestationWithNonce(att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signHarvest(IAgriOracleSubmitV1.Attestation memory att, address who, uint256 pk)
        internal
        returns (bytes memory)
    {
        vm.prank(who);
        (bytes32 digest, ) = harvest.hashAttestationWithNonce(att);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
