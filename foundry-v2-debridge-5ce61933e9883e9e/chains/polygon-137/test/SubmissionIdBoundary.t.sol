// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "../src/SignatureVerifier_fe7d/contracts/libraries/SignatureUtil.sol";

/// @dev A small executable model of the active Gate's submission-id boundary.
/// It intentionally keeps the source-side bytes fields and claim-side address
/// fields separate so a test cannot accidentally hide a serialization change.
contract SubmissionIdBoundaryHarness {
    using SignatureUtil for bytes;
    using SignatureUtil for bytes32;

    uint256 internal constant SUBMISSION_PREFIX = 1;
    uint256 internal constant SEND_HASHED_DATA = 3;

    function sourceRegular(
        bytes32 debridgeId,
        uint256 sourceChain,
        uint256 destinationChain,
        uint256 amount,
        bytes memory receiver,
        uint256 nonce
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            SUBMISSION_PREFIX,
            debridgeId,
            sourceChain,
            destinationChain,
            amount,
            receiver,
            nonce
        ));
    }

    function claimRegular(
        bytes32 debridgeId,
        uint256 sourceChain,
        uint256 destinationChain,
        uint256 amount,
        address receiver,
        uint256 nonce
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            SUBMISSION_PREFIX,
            debridgeId,
            sourceChain,
            destinationChain,
            amount,
            receiver,
            nonce
        ));
    }

    function sourceAuto(
        bytes32 debridgeId,
        uint256 sourceChain,
        uint256 destinationChain,
        uint256 amount,
        bytes memory receiver,
        uint256 nonce,
        uint256 executionFee,
        uint256 flags,
        bytes memory fallbackAddress,
        bytes memory data,
        address sender
    ) external pure returns (bytes32) {
        bytes memory packedSubmission = abi.encodePacked(
            SUBMISSION_PREFIX,
            debridgeId,
            sourceChain,
            destinationChain,
            amount,
            receiver,
            nonce
        );
        bool isHashedData = ((flags >> SEND_HASHED_DATA) & 1) == 1;
        require(!isHashedData || data.length == 32, "source validation");
        return keccak256(abi.encodePacked(
            packedSubmission,
            executionFee,
            flags,
            keccak256(fallbackAddress),
            isHashedData ? data : abi.encodePacked(keccak256(data)),
            keccak256(abi.encodePacked(sender))
        ));
    }

    function claimAuto(
        bytes32 debridgeId,
        uint256 sourceChain,
        uint256 destinationChain,
        uint256 amount,
        address receiver,
        uint256 nonce,
        uint256 executionFee,
        uint256 flags,
        address fallbackAddress,
        bytes memory data,
        bytes memory nativeSender,
        address claimant
    ) external pure returns (bytes32) {
        bytes memory packedSubmission = abi.encodePacked(
            SUBMISSION_PREFIX,
            debridgeId,
            sourceChain,
            destinationChain,
            amount,
            receiver,
            nonce
        );
        bool isHashedData = ((flags >> SEND_HASHED_DATA) & 1) == 1
            && claimant == fallbackAddress
            && data.length == 32;
        return keccak256(abi.encodePacked(
            packedSubmission,
            executionFee,
            flags,
            keccak256(abi.encodePacked(fallbackAddress)),
            isHashedData ? data : abi.encodePacked(keccak256(data)),
            keccak256(nativeSender)
        ));
    }

    function countSignatures(bytes memory signatures) external pure returns (uint256) {
        return signatures.length % 65 == 0 ? signatures.length / 65 : 0;
    }

    function parse(bytes memory signatures, uint256 offset)
        external
        pure
        returns (bytes32 r, bytes32 s, uint8 v)
    {
        return SignatureUtil.parseSignature(signatures, offset);
    }

    function unsigned(bytes32 submissionId) external pure returns (bytes32) {
        return submissionId.getUnsignedMsg();
    }
}

contract SubmissionIdBoundaryTest {
    bytes32 internal constant DEBRIDGE_ID = keccak256("asset");
    uint256 internal constant SOURCE_CHAIN = 1;
    uint256 internal constant DESTINATION_CHAIN = 137;
    uint256 internal constant AMOUNT = 123456789;
    uint256 internal constant NONCE = 42;
    address internal constant RECEIVER = 0x1234567890123456789012345678901234567890;
    address internal constant FALLBACK = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
    address internal constant SENDER = 0x9876543210987654321098765432109876543210;

    function testCanonicalRegularReceiverBytesMatchClaimAddress() external {
        SubmissionIdBoundaryHarness h = new SubmissionIdBoundaryHarness();
        bytes32 sourceId = h.sourceRegular(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            abi.encodePacked(RECEIVER),
            NONCE
        );
        bytes32 claimId = h.claimRegular(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            RECEIVER,
            NONCE
        );
        require(sourceId == claimId, "canonical source/claim mismatch");
    }

    function testNonCanonicalReceiverLengthCannotAliasFixedClaimPreimage() external {
        SubmissionIdBoundaryHarness h = new SubmissionIdBoundaryHarness();
        bytes memory canonical = abi.encodePacked(RECEIVER);
        bytes memory shortReceiver = new bytes(19);
        bytes memory longReceiver = new bytes(21);
        for (uint256 i = 0; i < canonical.length; i++) {
            if (i < shortReceiver.length) shortReceiver[i] = canonical[i];
            longReceiver[i] = canonical[i];
        }
        longReceiver[20] = 0x01;

        bytes32 canonicalId = h.sourceRegular(
            DEBRIDGE_ID, SOURCE_CHAIN, DESTINATION_CHAIN, AMOUNT, canonical, NONCE
        );
        bytes32 shortId = h.sourceRegular(
            DEBRIDGE_ID, SOURCE_CHAIN, DESTINATION_CHAIN, AMOUNT, shortReceiver, NONCE
        );
        bytes32 longId = h.sourceRegular(
            DEBRIDGE_ID, SOURCE_CHAIN, DESTINATION_CHAIN, AMOUNT, longReceiver, NONCE
        );
        require(shortId != canonicalId && longId != canonicalId, "receiver length alias");
        // The fixed-width suffix follows the variable receiver. Different
        // receiver lengths therefore produce different preimage lengths and
        // cannot be reinterpreted as another address/nonce tuple.
    }

    function testAutoHashedDataOnlyMatchesFallbackRecoveryBranch() external {
        SubmissionIdBoundaryHarness h = new SubmissionIdBoundaryHarness();
        uint256 hashedFlags = uint256(1) << 3;
        bytes memory dataHash = abi.encodePacked(keccak256("signed call"));
        bytes memory fallbackBytes = abi.encodePacked(FALLBACK);
        bytes32 sourceId = h.sourceAuto(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            abi.encodePacked(RECEIVER),
            NONCE,
            7,
            hashedFlags,
            fallbackBytes,
            dataHash,
            SENDER
        );
        bytes32 fallbackClaimId = h.claimAuto(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            RECEIVER,
            NONCE,
            7,
            hashedFlags,
            FALLBACK,
            dataHash,
            abi.encodePacked(SENDER),
            FALLBACK
        );
        bytes32 ordinaryRelayerId = h.claimAuto(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            RECEIVER,
            NONCE,
            7,
            hashedFlags,
            FALLBACK,
            dataHash,
            abi.encodePacked(SENDER),
            address(0xBEEF)
        );
        require(sourceId == fallbackClaimId, "fallback recovery mismatch");
        require(sourceId != ordinaryRelayerId, "ordinary relayer bypassed hash branch");
    }

    /// @dev The Gate treats every uint256 flag as data; only the low defined
    /// bits have semantics.  Unknown high/reserved bits are still accepted
    /// by the source hash path, so the validator must preserve all 256 bits.
    function testHighReservedFlagIsAcceptedBySourceHashPath() external {
        SubmissionIdBoundaryHarness h = new SubmissionIdBoundaryHarness();
        uint256 flags = uint256(1) << 64;
        bytes memory data = hex"aa";
        bytes32 sourceId = h.sourceAuto(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            abi.encodePacked(RECEIVER),
            NONCE,
            7,
            flags,
            abi.encodePacked(FALLBACK),
            data,
            SENDER
        );
        require(sourceId != bytes32(0), "source hash unexpectedly rejected");
    }

    function testAutoNativeSenderIsHashBound() external {
        SubmissionIdBoundaryHarness h = new SubmissionIdBoundaryHarness();
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", RECEIVER, 1);
        uint256 flags = 0;
        bytes32 sourceId = h.sourceAuto(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            abi.encodePacked(RECEIVER),
            NONCE,
            0,
            flags,
            abi.encodePacked(FALLBACK),
            data,
            SENDER
        );
        bytes32 matchingClaimId = h.claimAuto(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            RECEIVER,
            NONCE,
            0,
            flags,
            FALLBACK,
            data,
            abi.encodePacked(SENDER),
            address(0xBEEF)
        );
        bytes32 wrongSenderId = h.claimAuto(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            RECEIVER,
            NONCE,
            0,
            flags,
            FALLBACK,
            data,
            abi.encodePacked(address(0xCAFE)),
            address(0xBEEF)
        );
        require(sourceId == matchingClaimId, "ordinary auto mismatch");
        require(sourceId != wrongSenderId, "native sender not bound");
    }

    function testAutoFallbackIsHashBound() external {
        SubmissionIdBoundaryHarness h = new SubmissionIdBoundaryHarness();
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", RECEIVER, 1);
        uint256 flags = 0;
        bytes32 sourceId = h.sourceAuto(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            abi.encodePacked(RECEIVER),
            NONCE,
            0,
            flags,
            abi.encodePacked(FALLBACK),
            data,
            SENDER
        );
        bytes32 wrongFallbackId = h.claimAuto(
            DEBRIDGE_ID,
            SOURCE_CHAIN,
            DESTINATION_CHAIN,
            AMOUNT,
            RECEIVER,
            NONCE,
            0,
            flags,
            address(0xCAFE),
            data,
            abi.encodePacked(SENDER),
            address(0xBEEF)
        );
        require(sourceId != wrongFallbackId, "fallback not bound");
    }

    function testMalformedSignatureLengthsAreNotCounted() external {
        SubmissionIdBoundaryHarness h = new SubmissionIdBoundaryHarness();
        require(h.countSignatures(new bytes(0)) == 0, "empty count");
        require(h.countSignatures(new bytes(65)) == 1, "one signature count");
        require(h.countSignatures(new bytes(130)) == 2, "two signature count");
        require(h.countSignatures(new bytes(64)) == 0, "short signature accepted");
        require(h.countSignatures(new bytes(66)) == 0, "trailing bytes accepted");
    }

    function testParserRejectsInvalidVAndAcceptsCompactV() external {
        SubmissionIdBoundaryHarness h = new SubmissionIdBoundaryHarness();
        bytes memory compact = new bytes(65);
        compact[64] = bytes1(uint8(0));
        (bytes32 r, bytes32 s, uint8 v) = h.parse(compact, 0);
        require(r == bytes32(0) && s == bytes32(0) && v == 27, "compact v parse");

        bytes memory invalid = new bytes(65);
        invalid[64] = bytes1(uint8(2));
        (bool ok, ) = address(h).call(
            abi.encodeWithSelector(h.parse.selector, invalid, uint256(0))
        );
        require(!ok, "invalid v accepted");
    }
}
