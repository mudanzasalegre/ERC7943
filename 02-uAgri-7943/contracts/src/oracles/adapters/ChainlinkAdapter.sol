// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @dev Minimal Chainlink AggregatorV3 interface subset.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkAdapter
/// @notice Optional helper to normalize Chainlink feed reads into a payloadHash usable inside oracle attestations.
/// @dev This contract does NOT submit attestations. It only reads feeds and computes a canonical commitment.
contract ChainlinkAdapter {
    error ChainlinkAdapter__InvalidFeed();
    error ChainlinkAdapter__Stale(uint256 updatedAt, uint256 nowTs);
    error ChainlinkAdapter__InvalidAnswer();

    /// @notice Reads the latest feed data and enforces an optional staleness bound.
    /// @param maxStalenessSeconds 0 disables staleness check, else updatedAt must be >= now - maxStalenessSeconds.
    function readLatest(address feed, uint256 maxStalenessSeconds)
        public
        view
        returns (int256 answer, uint8 decimals, uint256 updatedAt)
    {
        if (feed == address(0)) revert ChainlinkAdapter__InvalidFeed();

        ( , answer, , updatedAt, ) = IAggregatorV3(feed).latestRoundData();
        decimals = IAggregatorV3(feed).decimals();

        if (answer <= 0) revert ChainlinkAdapter__InvalidAnswer();

        if (maxStalenessSeconds != 0) {
            uint256 nowTs = block.timestamp;
            if (updatedAt == 0 || updatedAt + maxStalenessSeconds < nowTs) {
                revert ChainlinkAdapter__Stale(updatedAt, nowTs);
            }
        }
    }

    /// @notice Canonical hash commitment for a feed observation.
    /// @dev Encodes feed address + answer + decimals + updatedAt.
    function hashFeedObservation(address feed, int256 answer, uint8 decimals, uint256 updatedAt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(feed, answer, decimals, updatedAt));
    }

    /// @notice Reads latest and returns a ready-to-use payloadHash.
    function payloadHashLatest(address feed, uint256 maxStalenessSeconds)
        external
        view
        returns (bytes32 payloadHash, int256 answer, uint8 decimals, uint256 updatedAt)
    {
        (answer, decimals, updatedAt) = readLatest(feed, maxStalenessSeconds);
        payloadHash = hashFeedObservation(feed, answer, decimals, updatedAt);
    }
}
