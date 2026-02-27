// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RoleManager} from "src/access/RoleManager.sol";
import {UAgriRoles} from "src/interfaces/constants/UAgriRoles.sol";

import {TraceabilityRegistry} from "src/trace/TraceabilityRegistry.sol";
import {DocumentRegistry} from "src/trace/DocumentRegistry.sol";
import {BatchMerkleAnchor} from "src/trace/BatchMerkleAnchor.sol";

import {IdentityAttestation} from "src/compliance/IdentityAttestation.sol";
import {ComplianceModuleV1} from "src/compliance/ComplianceModuleV1.sol";
import {IAgriIdentityAttestationV1} from "src/interfaces/v1/IAgriIdentityAttestationV1.sol";

contract CovShortReturnIdentity {
    fallback() external payable {}
}

contract CovIdentity1271Signer {
    bool public valid = true;
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function setValid(bool v) external {
        valid = v;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4 magicValue) {
        return valid ? MAGIC : bytes4(0);
    }

    function registerVia(
        IdentityAttestation identity,
        address account,
        IAgriIdentityAttestationV1.Payload calldata payload,
        uint64 deadline,
        bytes calldata sig
    ) external {
        identity.register(account, payload, deadline, sig);
    }
}

contract TraceAndDocsCoverageTest is Test {
    RoleManager internal rm;
    TraceabilityRegistry internal trace;
    DocumentRegistry internal docs;
    BatchMerkleAnchor internal batch;

    address internal outsider = makeAddr("outsider");
    address internal custodyAttester = makeAddr("custody-attester");
    address internal oracleUpdater = makeAddr("oracle-updater");

    bytes32 internal constant CID = keccak256("cov-campaign");
    bytes32 internal constant PLOT = keccak256("cov-plot");
    bytes32 internal constant LOT = keccak256("cov-lot");

    function setUp() public {
        rm = new RoleManager(address(this));
        trace = new TraceabilityRegistry(address(rm));
        docs = new DocumentRegistry(address(rm));
        batch = new BatchMerkleAnchor(address(rm));
    }

    function testInitGuardsAndRoleManagerSetters() public {
        vm.expectRevert(TraceabilityRegistry.TraceabilityRegistry__AlreadyInitialized.selector);
        trace.initialize(address(rm));
        vm.expectRevert(DocumentRegistry.DocumentRegistry__BadInit.selector);
        docs.initialize(address(rm));
        vm.expectRevert(BatchMerkleAnchor.BatchMerkleAnchor__AlreadyInitialized.selector);
        batch.initialize(address(rm));

        vm.prank(outsider);
        vm.expectRevert(TraceabilityRegistry.TraceabilityRegistry__Unauthorized.selector);
        trace.setRoleManager(address(1));
        vm.prank(outsider);
        vm.expectRevert(DocumentRegistry.DocumentRegistry__Unauthorized.selector);
        docs.setRoleManager(address(1));
        vm.prank(outsider);
        vm.expectRevert(BatchMerkleAnchor.BatchMerkleAnchor__Unauthorized.selector);
        batch.setRoleManager(address(1));

        RoleManager newRm = new RoleManager(address(this));
        trace.setRoleManager(address(newRm));
        docs.setRoleManager(address(newRm));
        batch.setRoleManager(address(newRm));

        assertEq(address(trace.roleManager()), address(newRm));
        assertEq(address(docs.roleManager()), address(newRm));
        assertEq(address(batch.roleManager()), address(newRm));
    }

    function testTraceRegistryValidationAndAnchorPaths() public {
        uint64 fromTs = uint64(block.timestamp);
        uint64 toTs = uint64(block.timestamp + 1);
        bytes32 dataHash = keccak256("trace-data");
        bytes32 root = keccak256("trace-root");

        vm.prank(outsider);
        vm.expectRevert(TraceabilityRegistry.TraceabilityRegistry__Unauthorized.selector);
        trace.emitTrace(CID, PLOT, LOT, 1, dataHash, fromTs, toTs, "ipfs://x");

        rm.grantRole(UAgriRoles.CUSTODY_ATTESTER_ROLE, custodyAttester);

        vm.prank(custodyAttester);
        vm.expectRevert(TraceabilityRegistry.TraceabilityRegistry__InvalidDataHash.selector);
        trace.emitTrace(CID, PLOT, LOT, 1, bytes32(0), fromTs, toTs, "ipfs://x");

        vm.prank(custodyAttester);
        vm.expectRevert(TraceabilityRegistry.TraceabilityRegistry__InvalidTimeRange.selector);
        trace.emitTrace(CID, PLOT, LOT, 1, dataHash, toTs, fromTs, "ipfs://x");

        vm.prank(custodyAttester);
        vm.expectRevert(TraceabilityRegistry.TraceabilityRegistry__PointerTooLong.selector);
        trace.emitTrace(CID, PLOT, LOT, 1, dataHash, fromTs, toTs, _longPointer());

        vm.prank(custodyAttester);
        trace.emitTrace(CID, PLOT, LOT, 77, dataHash, fromTs, toTs, "ipfs://trace-ok");

        TraceabilityRegistry.LotHead memory head = trace.lotHead(CID, PLOT, LOT);
        assertEq(head.count, 1);
        assertEq(head.lastEventType, 77);
        assertEq(head.lastDataHash, dataHash);
        assertEq(head.lastToTs, toTs);

        vm.prank(outsider);
        vm.expectRevert(TraceabilityRegistry.TraceabilityRegistry__Unauthorized.selector);
        trace.anchorRoot(CID, 1, root, fromTs, toTs);

        vm.prank(custodyAttester);
        vm.expectRevert(TraceabilityRegistry.TraceabilityRegistry__InvalidRoot.selector);
        trace.anchorRoot(CID, 1, bytes32(0), fromTs, toTs);

        vm.prank(custodyAttester);
        vm.expectRevert(TraceabilityRegistry.TraceabilityRegistry__InvalidTimeRange.selector);
        trace.anchorRoot(CID, 1, root, toTs, fromTs);

        vm.prank(custodyAttester);
        trace.anchorRoot(CID, 1, root, fromTs, toTs);

        assertEq(trace.anchored(CID, 1), 1);
        TraceabilityRegistry.RootAnchor memory a = trace.getAnchor(CID, 1, 0);
        assertEq(a.root, root);
        assertEq(a.fromTs, fromTs);
        assertEq(a.toTs, toTs);
        assertEq(a.issuer, custodyAttester);
        assertTrue(trace.isAnchored(CID, 1, root, fromTs, toTs));

        vm.prank(custodyAttester);
        vm.expectRevert(abi.encodeWithSelector(TraceabilityRegistry.TraceabilityRegistry__AlreadyAnchored.selector, keccak256(abi.encode(CID, uint32(1), root, fromTs, toTs))));
        trace.anchorRoot(CID, 1, root, fromTs, toTs);
    }

    function testBatchMerkleAnchorValidationAndViews() public {
        uint64 fromTs = uint64(block.timestamp);
        uint64 toTs = uint64(block.timestamp + 2);
        bytes32 root = keccak256("batch-root");

        vm.prank(outsider);
        vm.expectRevert(BatchMerkleAnchor.BatchMerkleAnchor__Unauthorized.selector);
        batch.anchorRoot(CID, 9, root, fromTs, toTs);

        rm.grantRole(UAgriRoles.CUSTODY_ATTESTER_ROLE, custodyAttester);

        vm.prank(custodyAttester);
        vm.expectRevert(BatchMerkleAnchor.BatchMerkleAnchor__InvalidRoot.selector);
        batch.anchorRoot(CID, 9, bytes32(0), fromTs, toTs);

        vm.prank(custodyAttester);
        vm.expectRevert(BatchMerkleAnchor.BatchMerkleAnchor__InvalidTimeRange.selector);
        batch.anchorRoot(CID, 9, root, toTs, fromTs);

        vm.prank(custodyAttester);
        batch.anchorRoot(CID, 9, root, fromTs, toTs);

        assertEq(batch.anchored(CID, 9), 1);
        BatchMerkleAnchor.Anchor memory a = batch.getAnchor(CID, 9, 0);
        assertEq(a.root, root);
        assertEq(a.fromTs, fromTs);
        assertEq(a.toTs, toTs);
        assertEq(a.issuer, custodyAttester);
        assertTrue(batch.isAnchored(CID, 9, root, fromTs, toTs));

        vm.prank(custodyAttester);
        vm.expectRevert(abi.encodeWithSelector(BatchMerkleAnchor.BatchMerkleAnchor__AlreadyAnchored.selector, keccak256(abi.encode(CID, uint32(9), root, fromTs, toTs))));
        batch.anchorRoot(CID, 9, root, fromTs, toTs);
    }

    function testDocumentRegistryPathsAndRoleChecks() public {
        bytes32 docHash1 = keccak256("doc-1");
        bytes32 docHash2 = keccak256("doc-2");
        uint64 issuedAt = uint64(block.timestamp);

        vm.prank(outsider);
        vm.expectRevert(DocumentRegistry.DocumentRegistry__Unauthorized.selector);
        docs.registerDoc(1, docHash1, issuedAt, CID, PLOT, LOT, "ipfs://doc-1");

        rm.grantRole(UAgriRoles.CUSTODY_ATTESTER_ROLE, custodyAttester);
        rm.grantRole(UAgriRoles.ORACLE_UPDATER_ROLE, oracleUpdater);

        vm.prank(custodyAttester);
        vm.expectRevert(DocumentRegistry.DocumentRegistry__InvalidHash.selector);
        docs.registerDoc(1, bytes32(0), issuedAt, CID, PLOT, LOT, "ipfs://doc-x");

        vm.prank(custodyAttester);
        vm.expectRevert(DocumentRegistry.DocumentRegistry__InvalidIssuedAt.selector);
        docs.registerDoc(1, docHash1, 0, CID, PLOT, LOT, "ipfs://doc-x");

        vm.prank(custodyAttester);
        vm.expectRevert(DocumentRegistry.DocumentRegistry__PointerTooLong.selector);
        docs.registerDoc(1, docHash1, issuedAt, CID, PLOT, LOT, _longPointer());

        vm.prank(custodyAttester);
        docs.registerDoc(1, docHash1, issuedAt, CID, PLOT, LOT, "ipfs://doc-1");

        vm.prank(custodyAttester);
        vm.expectRevert(abi.encodeWithSelector(DocumentRegistry.DocumentRegistry__AlreadyRegistered.selector, docHash1));
        docs.registerDoc(1, docHash1, issuedAt, CID, PLOT, LOT, "ipfs://doc-dup");

        vm.prank(oracleUpdater);
        docs.registerDoc(1, docHash2, issuedAt + 1, CID, PLOT, LOT, "ipfs://doc-2");

        bytes32 key = docs.docKeyOf(1, CID, PLOT, LOT);
        assertEq(docs.latestVersion(1, CID, PLOT, LOT), 2);
        assertEq(docs.latestDocHash(1, CID, PLOT, LOT), docHash2);
        assertEq(docs.docHashAtVersion(key, 1), docHash1);
        assertEq(docs.docHashAtVersion(key, 2), docHash2);

        (bool exists,,,,,,,,,) = docs.docInfo(keccak256("unknown-doc"));
        assertFalse(exists);

        (bool exists2,, uint32 version,,,,,, bytes32 pointerHash, bytes32 prevHash) = docs.docInfo(docHash2);
        assertTrue(exists2);
        assertEq(version, 2);
        assertEq(pointerHash, keccak256(bytes("ipfs://doc-2")));
        assertEq(prevHash, docHash1);
    }

    function _longPointer() internal pure returns (string memory s) {
        bytes memory b = new bytes(2049);
        for (uint256 i = 0; i < b.length; i++) {
            b[i] = bytes1(uint8(97));
        }
        s = string(b);
    }
}

contract IdentityComplianceCoverageTest is Test {
    RoleManager internal rm;
    IdentityAttestation internal identity;
    ComplianceModuleV1 internal compliance;

    address internal outsider = makeAddr("outsider");
    address internal officer = makeAddr("officer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal providerPk = 0xAA11;
    uint256 internal otherPk = 0xBB22;
    address internal provider;

    function setUp() public {
        rm = new RoleManager(address(this));
        identity = new IdentityAttestation(address(rm));
        compliance = new ComplianceModuleV1(address(rm), address(identity));
        provider = vm.addr(providerPk);
    }

    function testIdentityProviderAdminViewsAndInitGuard() public {
        vm.prank(outsider);
        vm.expectRevert();
        identity.setProvider(1, provider, true);

        address[] memory signers = new address[](1);
        signers[0] = provider;
        vm.expectRevert(IdentityAttestation.IdentityAttestation__InvalidProviderId.selector);
        identity.setProviderBatch(0, signers, true);

        signers[0] = address(0);
        vm.expectRevert(IdentityAttestation.IdentityAttestation__InvalidSigner.selector);
        identity.setProviderBatch(1, signers, true);

        signers[0] = provider;
        identity.setProviderBatch(1, signers, true);
        assertTrue(identity.isProvider(1, provider));
        assertEq(identity.nonces(alice, 1), 0);

        bytes32 ds = identity.domainSeparator();
        assertTrue(ds != bytes32(0));

        IAgriIdentityAttestationV1.Payload memory p = IAgriIdentityAttestationV1.Payload({
            jurisdiction: 34,
            tier: 2,
            flags: 1,
            expiry: uint64(block.timestamp + 1 days),
            lockupUntil: 0,
            providerId: 1
        });
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 d1 = identity.hashRegister(alice, p, deadline);
        (bytes32 d2, uint256 nonce) = identity.hashRegisterWithNonce(alice, p, deadline);
        assertEq(d1, d2);
        assertEq(nonce, 0);

        vm.expectRevert(IdentityAttestation.IdentityAttestation__AlreadyInitialized.selector);
        identity.initialize(address(rm));
    }

    function testIdentityRegisterEoaAndErrorPaths() public {
        identity.setProvider(7, provider, true);

        IAgriIdentityAttestationV1.Payload memory p = IAgriIdentityAttestationV1.Payload({
            jurisdiction: 34,
            tier: 2,
            flags: 1,
            expiry: uint64(block.timestamp + 3 days),
            lockupUntil: 0,
            providerId: 7
        });

        bytes memory sig = _signIdentity(address(0), p, uint64(block.timestamp + 1 days), providerPk);
        vm.expectRevert();
        identity.register(address(0), p, uint64(block.timestamp + 1 days), sig);

        p.providerId = 0;
        vm.expectRevert(IdentityAttestation.IdentityAttestation__InvalidProviderId.selector);
        identity.register(alice, p, uint64(block.timestamp + 1 days), hex"01");
        p.providerId = 7;

        vm.expectRevert();
        identity.register(alice, p, uint64(block.timestamp + 1 days), bytes(""));

        sig = _signIdentity(alice, p, uint64(block.timestamp + 10), providerPk);
        vm.warp(block.timestamp + 20);
        vm.expectRevert();
        identity.register(alice, p, uint64(block.timestamp - 1), sig);

        p.expiry = uint64(block.timestamp);
        sig = _signIdentity(alice, p, uint64(block.timestamp + 1 days), providerPk);
        vm.expectRevert(IdentityAttestation.IdentityAttestation__PayloadExpired.selector);
        identity.register(alice, p, uint64(block.timestamp + 1 days), sig);

        p.expiry = uint64(block.timestamp + 2 days);
        sig = _signIdentity(alice, p, uint64(block.timestamp + 1 days), otherPk);
        vm.expectRevert(IdentityAttestation.IdentityAttestation__ProviderNotAllowed.selector);
        identity.register(alice, p, uint64(block.timestamp + 1 days), sig);

        sig = _signIdentity(alice, p, uint64(block.timestamp + 1 days), providerPk);
        identity.register(alice, p, uint64(block.timestamp + 1 days), sig);
        assertEq(identity.nonces(alice, 7), 1);

        IAgriIdentityAttestationV1.Payload memory saved = identity.identityOf(alice);
        assertEq(saved.providerId, 7);
        assertEq(saved.jurisdiction, 34);
    }

    function testIdentityRegisterEip1271Path() public {
        CovIdentity1271Signer signer = new CovIdentity1271Signer();
        uint32 pid = 55;

        identity.setProvider(pid, address(signer), true);

        IAgriIdentityAttestationV1.Payload memory p = IAgriIdentityAttestationV1.Payload({
            jurisdiction: 250,
            tier: 3,
            flags: 9,
            expiry: uint64(block.timestamp + 7 days),
            lockupUntil: 0,
            providerId: pid
        });

        signer.registerVia(identity, alice, p, uint64(block.timestamp + 1 days), hex"01");
        assertEq(identity.nonces(alice, pid), 1);

        signer.setValid(false);
        vm.expectRevert();
        signer.registerVia(identity, bob, p, uint64(block.timestamp + 1 days), hex"01");
    }

    function testComplianceGovernanceAndBatchSetters() public {
        vm.prank(outsider);
        vm.expectRevert();
        compliance.setPaused(true);

        rm.grantRole(UAgriRoles.COMPLIANCE_OFFICER_ROLE, officer);
        vm.prank(officer);
        compliance.setPaused(false);

        ComplianceModuleV1.JurisdictionProfile[] memory arr = new ComplianceModuleV1.JurisdictionProfile[](1);
        uint16[] memory j2 = new uint16[](2);
        vm.expectRevert(ComplianceModuleV1.ComplianceModuleV1__ArrayLengthMismatch.selector);
        compliance.setProfileBatch(j2, arr);

        uint16[] memory fromJ = new uint16[](1);
        uint16[] memory toJ = new uint16[](2);
        vm.expectRevert(ComplianceModuleV1.ComplianceModuleV1__ArrayLengthMismatch.selector);
        compliance.setPairBlockedBatch(fromJ, toJ, true);

        vm.expectRevert(ComplianceModuleV1.ComplianceModuleV1__InvalidIdentityAttestation.selector);
        compliance.setIdentityAttestation(address(0));
        vm.expectRevert(ComplianceModuleV1.ComplianceModuleV1__InvalidIdentityAttestation.selector);
        compliance.setIdentityAttestation(address(1));

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        compliance.setDenylistedBatch(users, true);
        compliance.setSanctionedBatch(users, true);
        assertTrue(compliance.isDenylisted(alice));
        assertTrue(compliance.isSanctioned(bob));

        users[0] = address(0);
        vm.expectRevert();
        compliance.setDenylistedBatch(users, false);
        vm.expectRevert();
        compliance.setSanctionedBatch(users, false);

        ComplianceModuleV1.JurisdictionProfile memory p0 = ComplianceModuleV1.JurisdictionProfile({
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
        compliance.setProfile(0, p0);

        ComplianceModuleV1.JurisdictionProfile memory pMissing = compliance.profileOf(999);
        assertTrue(pMissing.enabled);

        p0.enabled = false;
        compliance.setProfile(0, p0);
        pMissing = compliance.profileOf(999);
        assertFalse(pMissing.enabled);

        vm.expectRevert(ComplianceModuleV1.ComplianceModuleV1__AlreadyInitialized.selector);
        compliance.initialize(address(rm), address(identity));
    }

    function testComplianceStatusAndValidationBranches() public {
        identity.setProvider(1, provider, true);

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
            minTtlSeconds: 1000,
            maxTransfer: 100
        });
        compliance.setProfile(0, strict);

        compliance.setIdentityAttestation(address(new CovShortReturnIdentity()));
        (bool ok, uint8 code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 30);
        compliance.setIdentityAttestation(address(identity));

        compliance.setExempt(alice, true);
        (ok, code) = compliance.transactStatus(alice);
        assertTrue(ok);
        assertEq(code, 0);
        compliance.setExempt(alice, false);

        IAgriIdentityAttestationV1.Payload memory pa = IAgriIdentityAttestationV1.Payload({
            jurisdiction: 10,
            tier: 2,
            flags: 1,
            expiry: 0,
            lockupUntil: 0,
            providerId: 1
        });

        _registerIdentity(alice, pa, uint64(block.timestamp + 1 days), providerPk);
        (ok, code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 35);

        pa.expiry = uint64(block.timestamp + 10);
        _registerIdentity(alice, pa, uint64(block.timestamp + 1 days), providerPk);
        (ok, code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 32);

        pa.expiry = uint64(block.timestamp + 3 days);
        pa.tier = 1;
        _registerIdentity(alice, pa, uint64(block.timestamp + 1 days), providerPk);
        (ok, code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 33);

        pa.tier = 4;
        _registerIdentity(alice, pa, uint64(block.timestamp + 1 days), providerPk);
        (ok, code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 33);

        pa.tier = 2;
        pa.flags = 0;
        _registerIdentity(alice, pa, uint64(block.timestamp + 1 days), providerPk);
        (ok, code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 34);

        pa.flags = 3;
        _registerIdentity(alice, pa, uint64(block.timestamp + 1 days), providerPk);
        (ok, code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 34);

        strict.minTtlSeconds = 0;
        compliance.setProfile(0, strict);
        pa.flags = 1;
        pa.expiry = uint64(block.timestamp + 1);
        _registerIdentity(alice, pa, uint64(block.timestamp + 1 days), providerPk);
        vm.warp(block.timestamp + 2);
        (ok, code) = compliance.transactStatus(alice);
        assertFalse(ok);
        assertEq(code, 31);

        pa.expiry = uint64(block.timestamp + 7 days);
        pa.lockupUntil = uint64(block.timestamp + 2 days);
        pa.jurisdiction = 100;
        _registerIdentity(alice, pa, uint64(block.timestamp + 1 days), providerPk);

        IAgriIdentityAttestationV1.Payload memory pb = IAgriIdentityAttestationV1.Payload({
            jurisdiction: 200,
            tier: 2,
            flags: 1,
            expiry: uint64(block.timestamp + 7 days),
            lockupUntil: 0,
            providerId: 1
        });
        _registerIdentity(bob, pb, uint64(block.timestamp + 1 days), providerPk);

        strict.sameJurisdictionOnly = true;
        compliance.setProfile(0, strict);
        (ok, code) = compliance.transferStatus(alice, bob, 50);
        assertFalse(ok);
        assertEq(code, 41);

        strict.sameJurisdictionOnly = false;
        compliance.setProfile(0, strict);
        compliance.setPairBlocked(100, 200, true);
        (ok, code) = compliance.transferStatus(alice, bob, 50);
        assertFalse(ok);
        assertEq(code, 41);

        compliance.setPairBlocked(100, 200, false);
        (ok, code) = compliance.transferStatus(alice, bob, 50);
        assertFalse(ok);
        assertEq(code, 40);

        vm.warp(block.timestamp + 3 days);
        (ok, code) = compliance.transferStatus(alice, bob, 1000);
        assertFalse(ok);
        assertEq(code, 42);

        (ok, code) = compliance.transferStatus(carol, bob, 10);
        assertFalse(ok);
        assertEq(code, 30);

        (ok, code) = compliance.transferStatus(alice, carol, 10);
        assertFalse(ok);
        assertEq(code, 30);

        compliance.setDenylisted(alice, true);
        (ok, code) = compliance.transferStatus(alice, bob, 10);
        assertFalse(ok);
        assertEq(code, 10);
        compliance.setDenylisted(alice, false);

        compliance.setSanctioned(bob, true);
        (ok, code) = compliance.transferStatus(alice, bob, 10);
        assertFalse(ok);
        assertEq(code, 11);
        compliance.setSanctioned(bob, false);

        compliance.setPaused(true);
        (ok, code) = compliance.transferStatus(alice, bob, 10);
        assertFalse(ok);
        assertEq(code, 1);
    }

    function _registerIdentity(
        address account,
        IAgriIdentityAttestationV1.Payload memory payload,
        uint64 deadline,
        uint256 signerPk
    ) internal {
        bytes memory sig = _signIdentity(account, payload, deadline, signerPk);
        identity.register(account, payload, deadline, sig);
    }

    function _signIdentity(
        address account,
        IAgriIdentityAttestationV1.Payload memory payload,
        uint64 deadline,
        uint256 signerPk
    ) internal view returns (bytes memory) {
        bytes32 digest = identity.hashRegister(account, payload, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
