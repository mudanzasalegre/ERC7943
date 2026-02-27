// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title ClonesLib
/// @notice EIP-1167 minimal proxy cloning (CREATE / CREATE2).
/// @dev Keep assembly minimal to avoid coverage/instrumentation stack pressure.
library ClonesLib {
    error ClonesLib__InvalidImplementation();
    error ClonesLib__CreateFailed();

    function clone(address implementation) internal returns (address instance) {
        if (implementation.code.length == 0) revert ClonesLib__InvalidImplementation();
        bytes memory code = _creationCode(implementation);

        assembly ("memory-safe") {
            instance := create(0, add(code, 0x20), mload(code))
        }

        if (instance == address(0)) revert ClonesLib__CreateFailed();
    }

    function cloneDeterministic(address implementation, bytes32 salt) internal returns (address instance) {
        if (implementation.code.length == 0) revert ClonesLib__InvalidImplementation();
        bytes memory code = _creationCode(implementation);

        assembly ("memory-safe") {
            instance := create2(0, add(code, 0x20), mload(code), salt)
        }

        if (instance == address(0)) revert ClonesLib__CreateFailed();
    }

    function predictDeterministicAddress(
        address implementation,
        bytes32 salt,
        address deployer
    ) internal pure returns (address predicted) {
        bytes32 codeHash = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                implementation,
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );

        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)
                    )
                )
            )
        );
    }

    function predictDeterministicAddress(address implementation, bytes32 salt) internal view returns (address) {
        return predictDeterministicAddress(implementation, salt, address(this));
    }

    function _creationCode(address implementation) private pure returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
}
