// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "../src/DeBridgeGate_7971/contracts/interfaces/IDeBridgeGate.sol";
import "../src/DeBridgeGate_7971/contracts/transfers/DeBridgeGate.sol";

/// @dev Focused source-side check for the permissionless high-bit flags input.
/// The validator replay is the impact PoC; this test only checks the Gate's
/// submission-ID path with the exact active Gate implementation.
contract HighBitFlagsPoC {
    bytes32 private constant DEBRIDGE_ID = keccak256("asset");
    address private constant RECEIVER = 0x1234567890123456789012345678901234567890;
    address private constant FALLBACK = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
    address private constant SENDER = 0x9876543210987654321098765432109876543210;

    function testHighReservedFlagIsAcceptedBySourceHashPath() external {
        DeBridgeGate gate = new DeBridgeGate();

        IDeBridgeGate.SubmissionAutoParamsFrom memory autoParams =
            IDeBridgeGate.SubmissionAutoParamsFrom({
                executionFee: 7,
                flags: uint256(1) << 64,
                fallbackAddress: FALLBACK,
                data: hex"aa",
                nativeSender: abi.encodePacked(SENDER)
            });

        bytes32 submissionId = gate.getSubmissionIdFrom(
            DEBRIDGE_ID,
            1,
            123456789,
            RECEIVER,
            42,
            autoParams,
            true,
            SENDER
        );

        require(submissionId != bytes32(0), "high-bit flags were rejected");
    }
}
