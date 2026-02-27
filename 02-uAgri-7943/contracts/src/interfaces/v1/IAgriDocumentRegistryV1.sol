// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriDocumentRegistryV1 {
    event DocRegistered(
        uint32 indexed docType,
        bytes32 indexed docHash,
        address indexed issuer,
        uint64 issuedAt,
        bytes32 campaignId,
        bytes32 plotRef,
        bytes32 lotId,
        string pointer
    );

    function registerDoc(
        uint32 docType,
        bytes32 docHash,
        uint64 issuedAt,
        bytes32 campaignId,
        bytes32 plotRef,
        bytes32 lotId,
        string calldata pointer
    ) external;
}
