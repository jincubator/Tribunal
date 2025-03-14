// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibBytes} from "solady/utils/LibBytes.sol";

import {IDestinationSettler} from "./Interfaces/IDestinationSettler.sol";
import {Tribunal} from "./Tribunal.sol";

/// @title ERC7683Tribunal
/// @notice A contract that enables the tribunal compatibility with the ERC7683 destination settler interface.
contract ERC7683Tribunal is Tribunal, IDestinationSettler {
    // ======== Constructor ========
    constructor() {}

    // ======== External Functions ========
    /**
     * @notice Attempt to fill a cross-chain swap using ERC7683 interface.
     * @dev Unused initial parameter included for EIP7683 interface compatibility.
     * @param originData The encoded Claim and Mandate data.
     * @param fillerData The encoded claimant address.
     */
    function fill(bytes32, bytes calldata originData, bytes calldata fillerData) external {
        (
            uint256 chainId,
            Compact calldata compact,
            bytes calldata sponsorSignature,
            bytes calldata allocatorSignature,
            Mandate calldata mandate,
            address claimant
        ) = _parseCalldata(originData, fillerData);

        _fill(
            chainId,
            compact,
            sponsorSignature,
            allocatorSignature,
            mandate,
            claimant,
            _getBlockNumberish()
        );
    }

    /**
     * @notice Get a quote for any native tokens supplied to pay for dispensation (i.e. cost to trigger settlement).
     * @dev Unused initial parameter included for EIP7683 interface compatibility.
     * @param originData The encoded Claim and Mandate data.
     * @param fillerData The encoded claimant address.
     * @return dispensation The suggested dispensation amount.
     */
    function quote(bytes32, bytes calldata originData, bytes calldata fillerData)
        external
        view
        returns (uint256 dispensation)
    {
        (
            uint256 chainId,
            Compact calldata compact,
            bytes calldata sponsorSignature,
            bytes calldata allocatorSignature,
            Mandate calldata mandate,
            address claimant
        ) = _parseCalldata(originData, fillerData);

        return _quote(chainId, compact, sponsorSignature, allocatorSignature, mandate, claimant);
    }

    /**
     * @notice Parses the calldata to extract the necessary parameters without copying to memory.
     * @param originData The encoded Claim and Mandate data.
     * @param fillerData The encoded claimant address.
     * @return chainId The chain ID from the Claim.
     * @return compact The Compact struct from the Claim.
     * @return sponsorSignature The sponsor signature from the Claim.
     * @return allocatorSignature The allocator signature from the Claim.
     * @return mandate The Mandate struct.
     * @return claimant The claimant address.
     */
    function _parseCalldata(bytes calldata originData, bytes calldata fillerData)
        internal
        pure
        returns (
            uint256 chainId,
            Compact calldata compact,
            bytes calldata sponsorSignature,
            bytes calldata allocatorSignature,
            Mandate calldata mandate,
            address claimant
        )
    {
        /*
         * Need 19 words in originData at minimum:
         *  - 1 word for offset to claim (dynamic struct).
         *  - 7 words for mandate (fixed struct).
         *  - 7 words for fixed claim fields.
         *  - 2 words for signature offsets.
         *  - 2 words for signature lengths (assuming empty).
         * Also ensure no funny business with the claim pointer (should be 0x100).
         * Filler data should also have at least one word for claimant with no dirty bits.
         */
        assembly ("memory-safe") {
            if or(
                or(lt(originData.length, 0x260), xor(calldataload(originData.offset), 0x100)),
                or(lt(fillerData.length, 0x20), shr(calldataload(fillerData.offset), 0xa0))
            ) { revert(0, 0) }
        }

        // Get the claim struct encoded as a bytes array with bounds checks.
        bytes calldata encodedClaim = LibBytes.dynamicStructInCalldata(originData, 0x00);

        // Extract static structs and other static variables directly.
        // Note: This doesn't sanitize struct elements; that should happen downstream.
        assembly ("memory-safe") {
            chainId := calldataload(encodedClaim.offset)
            compact := add(encodedClaim.offset, 0x20)
            mandate := add(originData.offset, 0x20)
            claimant := calldataload(fillerData.offset)
        }

        // Get the sponsorSignature & allocatorSignature bytes arrays with bounds checks.
        // The two signature offsets are at words 8 + 9 in encoded claim, since
        // the first word is chainId and the next six make up the compact static struct.
        sponsorSignature = LibBytes.bytesInCalldata(encodedClaim, 0xe0);
        allocatorSignature = LibBytes.bytesInCalldata(encodedClaim, 0x100);
    }
}
