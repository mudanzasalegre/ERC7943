// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriTraceV1 {
    event TraceEvent(
        bytes32 indexed campaignId,
        bytes32 indexed plotRef,
        bytes32 indexed lotId,
        uint32 eventType,
        bytes32 dataHash,
        address issuer,
        uint64 fromTs,
        uint64 toTs,
        string pointer
    );

    event BatchRootAnchored(
        bytes32 indexed campaignId,
        uint32 indexed batchType,
        bytes32 root,
        uint64 fromTs,
        uint64 toTs,
        address issuer
    );

    function emitTrace(
        bytes32 campaignId,
        bytes32 plotRef,
        bytes32 lotId,
        uint32 eventType,
        bytes32 dataHash,
        uint64 fromTs,
        uint64 toTs,
        string calldata pointer
    ) external;

    function anchorRoot(
        bytes32 campaignId,
        uint32 batchType,
        bytes32 root,
        uint64 fromTs,
        uint64 toTs
    ) external;
}
