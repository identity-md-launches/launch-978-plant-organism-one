// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockToken} from "./PlantOrganism.t.sol";

// Protocol vector copied unchanged from the supplied oracle-consumer/REFERENCE.md.
// Its Sepolia domain and one-word answer exercise verification; application settlement
// intentionally requires Robinhood and three words, tested separately.
contract OracleConformanceTest is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    PlantOrganism consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        MockToken imd = new MockToken();
        deployCodeTo(
            "PlantOrganism.sol:PlantOrganism",
            abi.encode(address(imd), SIGNER, uint32(10223579), address(this)),
            VECTOR_CONSUMER
        );
        consumer = PlantOrganism(VECTOR_CONSUMER);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesUnchangedProtocolVector() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function test_acceptsUnchangedProtocolSignature() public view {
        consumer.verifyAttestation(vector(), VECTOR_SIGNATURE);
    }

    function test_acceptsFreshSignatureFromProtocolVectorKey() public view {
        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("another request");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        consumer.verifyAttestation(a, abi.encodePacked(r, s, v));
    }

    function test_settleSelectorUsesCanonicalAttestationTuple() public pure {
        assertEq(
            PlantOrganism.settle.selector,
            bytes4(
                keccak256(
                    "settle((bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                )
            )
        );
    }
}
