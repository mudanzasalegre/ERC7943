// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriMarketplaceV1 {
    event Listed(uint256 indexed id, address indexed seller, address sellToken, uint256 sellAmount, address buyToken, uint256 price);
    event Purchased(uint256 indexed id, address indexed buyer, uint256 amount, uint256 cost);
    event Cancelled(uint256 indexed id);

    function list(address sellToken, uint256 sellAmount, address buyToken, uint256 price) external returns (uint256 id);
    function buy(uint256 id, uint256 amount) external;
    function cancel(uint256 id) external;
}
