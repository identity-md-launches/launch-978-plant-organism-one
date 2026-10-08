// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title The reasoning oracle's attestation, as a contract reads it
/// @notice The oracle answers a typed question off chain — a panel of agents reads it, a deployer
/// reproduces the answer from the chain — and signs the result as EIP-712 typed data in the
/// *consumer's* domain: this chain, this contract. A signature for one consumer is meaningless to
/// another, which is the property that lets one attester key serve every consumer without any of
/// them being able to replay an answer into a neighbour.
///
/// @dev This library is the Solidity half of `oracle-eip712.ts` in `@identitymd/protocol`. The
/// struct, the type string and the domain name are copied from there field for field, and the
/// cross-implementation vector in `test/OracleAttestation.t.sol` is what keeps them equal: a digest
/// computed by viem on one side and `_hashTypedDataV4` on the other, over the same values. Change
/// either half and the vector fails before anything is signed for real.
library OracleAttestation {
    /// @dev Field order is the typed data's. `answer` is `abi.encode` of the value under
    /// `answerType`, so a consumer reads it back with one `abi.decode`; the hash covers
    /// `keccak256(answer)` as EIP-712 requires for a dynamic field.
    struct Attestation {
        /// @dev The request's UUID as sixteen raw bytes, left-aligned. The natural replay key.
        bytes32 requestId;
        /// @dev The chain the question is *about* — the one the recipe ran on. Not necessarily the
        /// consumer's chain, which is in the domain instead.
        uint256 chainId;
        /// @dev keccak-256 of the canonical question document. A consumer that pins its question
        /// compares this, so an answer to a different question cannot be presented as its own.
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        /// @dev The figure behind the answer where there is one: the sum, the leader's volume, the
        /// value compared. Zero otherwise.
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        /// @dev The closing block's hash, so a reorg cannot quietly change what was answered.
        bytes32 blockHash;
        /// @dev The panel job's UUID, the same way. Its page and receipt hold the evidence.
        bytes32 panelJobId;
        /// @dev How many seats the request opened. With `quorum`, what the requester asked for, so a
        /// consumer that does not pin its question can still refuse a panel of two.
        uint16 panelSize;
        /// @dev How many answers had to agree for the panel to settle.
        uint16 quorum;
        /// @dev How many members gave the answer signed. At least `quorum` when the panel agreed;
        /// below it only for chain evidence, when members who ran one recipe split and the
        /// deployer's own rerun settled which of their answers was whole. A consumer that wants the
        /// panel's agreement itself, not the rerun's, requires `agreed >= quorum`.
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    /// @dev The `answerType` codes. They are the protocol enum's order and are appended to, never
    /// reordered, because a code is what a signed attestation carries.
    uint8 internal constant ANSWER_BOOL = 0;
    uint8 internal constant ANSWER_ADDRESS = 1;
    uint8 internal constant ANSWER_BYTES32 = 2;
    uint8 internal constant ANSWER_UINT256 = 3;
    uint8 internal constant ANSWER_ADDRESS_LIST = 4;
    uint8 internal constant ANSWER_BYTES32_LIST = 5;

    string internal constant DOMAIN_NAME = "IdentityMD Oracle";
    /// @dev Version 2 added `panelSize`, `quorum` and `agreed`. A version 1 signature does not
    /// verify here and a version 2 one does not verify against a version 1 consumer.
    string internal constant DOMAIN_VERSION = "2";

    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    /// @notice The EIP-712 `hashStruct` of an attestation: what goes under the domain separator.
    /// @dev Encoded in two halves because sixteen values in one `abi.encode` is too deep a stack
    /// for the legacy code generator, and a consumer should not need via-IR to inherit this. Every
    /// value is a static 32-byte word, so the two halves concatenated are byte for byte the one
    /// encoding EIP-712 specifies.
    function hashStruct(Attestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
    }
}

