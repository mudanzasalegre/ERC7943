// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

interface IYieldAccumulatorPayoutOps {
    function hashPayoutClaim(
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash
    ) external view returns (bytes32);
    function claimToWithSig(
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash,
        bytes calldata signature
    ) external returns (uint256 paid);
    function confirmPayout(bytes32 ref, bytes32 receiptHash) external;
    function usedPayoutRef(bytes32 ref) external view returns (bool);
    function payoutByRef(bytes32 ref)
        external
        view
        returns (
            address account,
            address to,
            uint256 amount,
            bytes32 payoutRailHash,
            bytes32 receiptHash,
            uint256 liquidationIdAtRequest
        );
}

contract PayoutClaimTo is Script {
    function run() external {
        IYieldAccumulatorPayoutOps yieldAcc = IYieldAccumulatorPayoutOps(
            vm.envAddress("YIELD_ACC")
        );
        uint256 operatorPk = vm.envUint("PRIVATE_KEY");
        address operator = vm.addr(operatorPk);
        string memory mode = _readMode();

        if (_eq(mode, "CONFIRM")) {
            _runConfirm(yieldAcc, operatorPk, operator);
        } else {
            _runClaim(yieldAcc, operatorPk, operator);
        }
    }

    function _runClaim(
        IYieldAccumulatorPayoutOps yieldAcc,
        uint256 operatorPk,
        address operator
    ) internal {
        address account = vm.envAddress("ACCOUNT");
        address to = vm.envAddress("TO");
        uint256 maxAmount = vm.envUint("MAX_AMOUNT");
        uint64 deadline = uint64(vm.envOr("DEADLINE", uint256(0)));
        bytes32 ref = _readRef();
        bytes32 payoutRailHash = _readPayoutRailHash();
        bytes memory signature = _readClaimSignature(
            yieldAcc,
            account,
            to,
            maxAmount,
            deadline,
            ref,
            payoutRailHash
        );

        require(ref != bytes32(0), "REF_REQUIRED");
        require(signature.length != 0, "SIGNATURE_REQUIRED");

        vm.startBroadcast(operatorPk);
        uint256 paid = yieldAcc.claimToWithSig(
            account,
            to,
            maxAmount,
            deadline,
            ref,
            payoutRailHash,
            signature
        );
        vm.stopBroadcast();

        console2.log("mode: CLAIM");
        console2.log("operator:", operator);
        console2.log("yieldAcc:", address(yieldAcc));
        console2.log("account:", account);
        console2.log("to:", to);
        console2.log("maxAmount:", maxAmount);
        console2.log("deadline:", uint256(deadline));
        console2.logBytes32(ref);
        console2.logBytes32(payoutRailHash);
        console2.log("paid:", paid);
        console2.log("usedRef:", yieldAcc.usedPayoutRef(ref));
    }

    function _runConfirm(
        IYieldAccumulatorPayoutOps yieldAcc,
        uint256 operatorPk,
        address operator
    ) internal {
        bytes32 ref = _readRef();
        bytes32 receiptHash = _readReceiptHash();

        require(ref != bytes32(0), "REF_REQUIRED");
        require(receiptHash != bytes32(0), "RECEIPT_REQUIRED");

        vm.startBroadcast(operatorPk);
        yieldAcc.confirmPayout(ref, receiptHash);
        vm.stopBroadcast();

        console2.log("mode: CONFIRM");
        console2.log("operator:", operator);
        console2.log("yieldAcc:", address(yieldAcc));
        console2.logBytes32(ref);
        console2.logBytes32(receiptHash);
    }

    function _readClaimSignature(
        IYieldAccumulatorPayoutOps yieldAcc,
        address account,
        address to,
        uint256 maxAmount,
        uint64 deadline,
        bytes32 ref,
        bytes32 payoutRailHash
    ) internal view returns (bytes memory out) {
        try vm.envBytes("SIGNATURE") returns (bytes memory sig) {
            if (sig.length != 0) return sig;
        } catch {}

        try vm.envString("SIGNATURE_HEX") returns (string memory sigHex) {
            if (bytes(sigHex).length != 0) {
                bytes memory parsed = vm.parseBytes(sigHex);
                if (parsed.length != 0) return parsed;
            }
        } catch {}

        try vm.envUint("ACCOUNT_PK") returns (uint256 accountPk) {
            bytes32 digest = yieldAcc.hashPayoutClaim(
                account,
                to,
                maxAmount,
                deadline,
                ref,
                payoutRailHash
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountPk, digest);
            return abi.encodePacked(r, s, v);
        } catch {}

        return bytes("");
    }

    function _readMode() internal view returns (string memory mode) {
        mode = "CLAIM";
        try vm.envString("MODE") returns (string memory m) {
            if (bytes(m).length != 0) return m;
        } catch {}
        return mode;
    }

    function _readRef() internal view returns (bytes32 out) {
        try vm.envBytes32("REF") returns (bytes32 v) {
            if (v != bytes32(0)) return v;
        } catch {}

        try vm.envString("REF_STR") returns (string memory s) {
            if (bytes(s).length != 0) return keccak256(bytes(s));
        } catch {}

        return bytes32(0);
    }

    function _readPayoutRailHash() internal view returns (bytes32 out) {
        try vm.envBytes32("PAYOUT_RAIL_HASH") returns (bytes32 v) {
            return v;
        } catch {}

        try vm.envString("PAYOUT_RAIL_HASH_STR") returns (string memory s) {
            if (bytes(s).length != 0) return keccak256(bytes(s));
        } catch {}

        return bytes32(0);
    }

    function _readReceiptHash() internal view returns (bytes32 out) {
        try vm.envBytes32("RECEIPT_HASH") returns (bytes32 v) {
            if (v != bytes32(0)) return v;
        } catch {}

        try vm.envString("RECEIPT_HASH_STR") returns (string memory s) {
            if (bytes(s).length != 0) return keccak256(bytes(s));
        } catch {}

        return bytes32(0);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
