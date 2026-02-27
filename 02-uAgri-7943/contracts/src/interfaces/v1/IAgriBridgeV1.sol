// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriBridgeV1 {
    event BridgeOut(address indexed from, bytes32 indexed campaignId, uint256 amount, uint256 dstChainId, address indexed recipient, uint256 nonce);
    event BridgeIn(bytes32 indexed campaignId, uint256 amount, uint256 srcChainId, address indexed recipient, uint256 nonce);

    function bridgeOut(bytes32 campaignId, uint256 amount, uint256 dstChainId, address recipient) external returns (uint256 nonce);
    function bridgeIn(bytes32 campaignId, uint256 amount, uint256 srcChainId, address recipient, uint256 nonce, bytes calldata proof) external;
}
