// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ConsumerLib} from "the-compact/src/lib/ConsumerLib.sol";
import {ValidityLib} from "the-compact/src/lib/ValidityLib.sol";
import {FixedPointMathLib} from "the-compact/lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "the-compact/lib/solady/src/utils/SafeTransferLib.sol";
import {ECDSA} from "the-compact/lib/solady/src/utils/ECDSA.sol";

/**
 * @title Tribunal
 * @author 0age
 * @notice Tribunal is a framework for processing cross-chain swap settlements against PGA (priority gas auction)
 * blockchains. It ensures that tokens are transferred according to the mandate specified by the originating sponsor
 * and enforces that a single party is able to perform the settlement in the event of a dispute.
 * @dev This contract is under active development; contributions, reviews, and feedback are greatly appreciated.
 */
contract Tribunal {
    // ======== Libraries ========
    using ConsumerLib for uint256;
    using ValidityLib for uint256;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;
    using ECDSA for bytes32;

    // ======== Custom Errors ========
    error InvalidGasPrice();
    error InvalidSponsorSignature();

    // ======== Type Declarations ========

    struct Compact {
        uint256 chainId; // Claim processing chain ID
        address arbiter; // Claim verification account
        address sponsor; // Token source account
        uint256 nonce; // Replay protection parameter
        uint256 expires; // Claim expiration timestamp
        uint256 id; // Claimed ERC6909 token ID
        uint256 maximumAmount; // Maximum claimable tokens
        bytes sponsorSignature; // Authorization from the sponsor
        bytes allocatorSignature; // Authorization from the allocator
    }

    struct Mandate {
        bytes32 seal; // Replay protection parameter
        uint256 expires; // Mandate expiration timestamp
        address recipient; // Recipient of settled tokens
        address token; // Settlement token (address(0) for native)
        uint256 minimumAmount; // Minimum settlement amount
        uint256 baselinePriorityFee; // Base fee threshold where scaling kicks in
        uint256 scalingFactor; // Fee scaling multiplier (1e18 baseline)
    }

    struct Directive {
        address claimant; // Recipient of claimed tokens
        uint256 dispensation; // Cross-chain message layer payment
    }

    // ======== Constants ========

    /// @notice EIP-712 typehash for Mandate
    /// keccak256("Mandate(uint256 chainId,address tribunal,uint256 seal,uint256 expires,address recipient,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor)");
    bytes32 public constant MANDATE_TYPEHASH =
        0x883455415cd7baee708890604fd9d8331291c26420e774b9a28177c7b21b7453;

    /// @notice Base scaling factor (1e18)
    uint256 public constant BASE_SCALING_FACTOR = 1e18;

    // EIP-712 typehash for Compact with Mandate witness
    bytes32 internal constant COMPACT_TYPESTRING_WITH_MANDATE_WITNESS =
        0x08926dd9bece79c857e46832f501c4f359f78a1aa86769fb829103507acc293b;

    /// @dev `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`.
    bytes32 internal constant _DOMAIN_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    /// @dev `keccak256(bytes("The Compact"))`.
    bytes32 internal constant _THE_COMPACT_NAME_HASH =
        0x5e6f7b4e1ac3d625bac418bc955510b3e054cb6cc23cc27885107f080180b292;

    /// @dev `keccak256("0")`.
    bytes32 internal constant _THE_COMPACT_VERSION_HASH =
        0x044852b2a670ade5407e78fb2863c51de9fcb96542a07186fe3aeda6bb8a116d;

    /// @dev The Compact contract address
    address internal constant _THE_COMPACT = 0x00000000000018DF021Ff2467dF97ff846E09f48;

    // ======== Constructor ========

    constructor() {}

    // ======== External Functions ========

    /// @notice Returns the name of the contract
    function name() external pure returns (string memory) {
        return "Tribunal";
    }

    /**
     * @notice Submit a petition to process a cross-chain settlement
     * @param compact The claim parameters and constraints
     * @param mandate The settlement conditions and amount derivation parameters
     * @param directive The execution details
     * @return mandateHash The derived mandate hash
     * @return settlementAmount The amount of tokens to be settled
     * @return claimAmount The amount of tokens to be claimed
     * @dev Note: EIP-1271 sponsors are not currently supported
     */
    function petition(
        Compact calldata compact,
        Mandate calldata mandate,
        Directive calldata directive
    )
        external
        payable
        returns (bytes32 mandateHash, uint256 settlementAmount, uint256 claimAmount)
    {
        // Consume the seal (will revert if already used).
        uint256(mandate.seal).consumeNonceAsSponsor(compact.sponsor);

        // Ensure that the mandate has not expired.
        mandate.expires.later();

        // Derive mandate hash and amounts.
        mandateHash = deriveMandateHash(mandate);
        (settlementAmount, claimAmount) = deriveAmounts(
            compact.maximumAmount,
            mandate.minimumAmount,
            mandate.baselinePriorityFee,
            mandate.scalingFactor
        );

        // Verify sponsor's signature on the compact
        bytes32 claimHash = keccak256(
            abi.encode(
                COMPACT_TYPESTRING_WITH_MANDATE_WITNESS,
                compact.arbiter,
                compact.sponsor,
                compact.nonce,
                compact.expires,
                compact.id,
                compact.maximumAmount,
                mandateHash
            )
        );

        // Get domain separator and add it to claim hash
        bytes32 domainSeparator = toCompactDomainSeparator(compact.chainId);
        bytes32 domainHash = withDomain(claimHash, domainSeparator);

        // Verify signature matches sponsor (EIP-1271 sponsors not supported)
        if (domainHash.recover(compact.sponsorSignature) != compact.sponsor) {
            revert InvalidSponsorSignature();
        }

        // Handle native token withdrawals directly.
        if (mandate.token == address(0)) {
            mandate.recipient.safeTransferETH(settlementAmount);
            // Return any remaining ETH to the caller
            uint256 remaining = address(this).balance;
            if (remaining > 0) {
                msg.sender.safeTransferETH(remaining);
            }
        } else {
            // NOTE: settling fee-on-transfer tokens will result in fewer tokens
            // being received by the recipient. Be sure to acommodate for this when
            // providing the desired settlement amount.
            mandate.token.safeTransferFrom(msg.sender, mandate.recipient, settlementAmount);
        }

        // Process the directive
        _processDirective(compact, mandateHash, directive, claimAmount);
    }

    /**
     * @notice Get a quote for the required dispensation amount
     * @param compact The claim parameters and constraints
     * @param mandate The settlement conditions and amount derivation parameters
     * @param directive The execution details
     * @return The suggested dispensation amount
     */
    function quote(Compact calldata compact, Mandate calldata mandate, Directive calldata directive)
        external
        view
        returns (uint256)
    {
        compact;
        mandate;
        directive;
        // TODO: Implement quote logic
        return msg.sender.balance / 1000;
    }

    /**
     * @notice Get details about the compact witness
     * @return witnessTypeString The EIP-712 type string for the mandate
     * @return tokenArg The position of the token argument
     * @return amountArg The position of the amount argument
     */
    function getCompactWitnessDetails()
        external
        pure
        returns (string memory witnessTypeString, uint256 tokenArg, uint256 amountArg)
    {
        return (
            "Mandate mandate)Mandate(uint256 chainId,address tribunal,uint256 seal,uint256 expires,address recipient,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor)",
            5,
            6
        );
    }

    /**
     * @notice Check if a seal has been used
     * @param sponsor The token source account
     * @param seal The seal to check
     * @return Whether the seal has been used
     */
    function disposition(address sponsor, bytes32 seal) external view returns (bool) {
        return uint256(seal).isConsumedBySponsor(sponsor);
    }

    /**
     * @dev Derives the mandate hash using EIP-712 typed data
     * @param mandate The mandate containing all hash parameters
     * @return The derived mandate hash
     */
    function deriveMandateHash(Mandate calldata mandate) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                MANDATE_TYPEHASH,
                block.chainid,
                address(this),
                mandate.seal,
                mandate.expires,
                mandate.recipient,
                mandate.token,
                mandate.minimumAmount,
                mandate.baselinePriorityFee,
                mandate.scalingFactor
            )
        );
    }

    /**
     * @dev Derives settlement and claim amounts based on mandate parameters and current conditions
     * @param maximumAmount The maximum amount that can be claimed
     * @param minimumAmount The minimum amount that must be settled
     * @param baselinePriorityFee The baseline priority fee in wei
     * @param scalingFactor The scaling factor to apply per priority fee wei above baseline
     * @return settlementAmount The derived settlement amount
     * @return claimAmount The derived claim amount
     */
    function deriveAmounts(
        uint256 maximumAmount,
        uint256 minimumAmount,
        uint256 baselinePriorityFee,
        uint256 scalingFactor
    ) public view returns (uint256 settlementAmount, uint256 claimAmount) {
        // Get the priority fee above baseline
        uint256 priorityFeeAboveBaseline = _getPriorityFee(baselinePriorityFee);

        // If no fee above baseline, return original amounts
        if (priorityFeeAboveBaseline == 0) {
            return (minimumAmount, maximumAmount);
        }

        // Calculate the scaling multiplier based on priority fee
        uint256 scalingMultiplier;
        if (scalingFactor > 1e18) {
            // For exact-in, increase settlement amount
            scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * priorityFeeAboveBaseline);
            claimAmount = maximumAmount;
            settlementAmount = minimumAmount.mulWadUp(scalingMultiplier);
        } else {
            // For exact-out, decrease claim amount
            scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * priorityFeeAboveBaseline);
            settlementAmount = minimumAmount;
            claimAmount = maximumAmount.mulWad(scalingMultiplier);
        }

        return (settlementAmount, claimAmount);
    }

    /**
     * @notice Derive the domain separator for The Compact on the claim chain
     * @param claimChainId The chain ID where the claim will be processed
     * @return domainSeparator The domain separator
     */
    function toCompactDomainSeparator(uint256 claimChainId)
        internal
        pure
        returns (bytes32 domainSeparator)
    {
        assembly ("memory-safe") {
            // Retrieve the free memory pointer.
            let m := mload(0x40)

            // Prepare domain data: EIP-712 typehash, name hash, version hash, notarizing chain ID, and verifying contract.
            mstore(m, _DOMAIN_TYPEHASH)
            mstore(add(m, 0x20), _THE_COMPACT_NAME_HASH)
            mstore(add(m, 0x40), _THE_COMPACT_VERSION_HASH)
            mstore(add(m, 0x60), claimChainId)
            mstore(add(m, 0x80), _THE_COMPACT)

            // Derive the domain separator.
            domainSeparator := keccak256(m, 0xa0)
        }
    }

    /**
     * @notice Add domain separator to a hash following EIP-712
     * @param claimHash The hash to add domain to
     * @param domainSeparator The domain separator
     * @return domainHash The final EIP-712 hash
     */
    function withDomain(bytes32 claimHash, bytes32 domainSeparator)
        internal
        pure
        returns (bytes32 domainHash)
    {
        assembly ("memory-safe") {
            // Retrieve and cache the free memory pointer.
            let m := mload(0x40)

            // Prepare the 712 prefix.
            mstore(0, 0x1901)

            // Prepare the domain separator.
            mstore(0x20, domainSeparator)

            // Prepare the message hash and compute the domain hash.
            mstore(0x40, claimHash)
            domainHash := keccak256(0x1e, 0x42)

            // Restore the free memory pointer.
            mstore(0x40, m)
        }
    }

    // ======== Internal Functions ========

    /**
     * @dev Process the directive for token claims
     * @param compact The claim parameters
     * @param mandateHash The derived mandate hash
     * @param directive The execution details
     * @param claimAmount The amount to claim
     */
    function _processDirective(
        Compact memory compact,
        bytes32 mandateHash,
        Directive memory directive,
        uint256 claimAmount
    ) internal {
        // TODO: Implement directive processing
    }

    /**
     * @dev Calculates the priority fee above the baseline
     * @param baselinePriorityFee The base fee threshold where scaling kicks in
     * @return priorityFee The priority fee above baseline (or 0 if below)
     */
    function _getPriorityFee(uint256 baselinePriorityFee)
        internal
        view
        returns (uint256 priorityFee)
    {
        if (tx.gasprice < block.basefee) revert InvalidGasPrice();
        unchecked {
            priorityFee = tx.gasprice - block.basefee;
            if (priorityFee > baselinePriorityFee) {
                priorityFee -= baselinePriorityFee;
            } else {
                priorityFee = 0;
            }
        }
    }
}
