// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "the-compact/lib/solady/src/utils/FixedPointMathLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TribunalTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    MockERC20 public token;
    address sponsor;
    uint256 sponsorPrivateKey;
    bytes32 constant REFERENCE_MANDATE_TYPEHASH = keccak256(
        "Mandate(uint256 chainId,address tribunal,uint256 seal,uint256 expires,address recipient,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor)"
    );

    // Compact type string with mandate witness
    bytes32 constant COMPACT_TYPESTRING_WITH_MANDATE_WITNESS =
        0x08926dd9bece79c857e46832f501c4f359f78a1aa86769fb829103507acc293b;

    // Make test contract payable to receive ETH refunds
    receive() external payable {}

    function setUp() public {
        tribunal = new Tribunal();
        token = new MockERC20();
        (sponsor, sponsorPrivateKey) = makeAddrAndKey("sponsor");
    }

    /**
     * @notice Verify that the contract name is correctly set to "Tribunal"
     */
    function test_Name() public view {
        assertEq(tribunal.name(), "Tribunal");
    }

    /**
     * @notice Verify that mandate hash derivation follows EIP-712 structured data hashing
     * @dev Tests mandate hash derivation with a seal value of 1
     */
    function test_DeriveMandateHash() public view {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            seal: bytes32(uint256(1)),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            recipient: address(0xCAFE),
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18
        });

        bytes32 expectedHash = keccak256(
            abi.encode(
                REFERENCE_MANDATE_TYPEHASH,
                block.chainid,
                address(tribunal),
                uint256(mandate.seal),
                mandate.expires,
                mandate.recipient,
                mandate.token,
                mandate.minimumAmount,
                mandate.baselinePriorityFee,
                mandate.scalingFactor
            )
        );

        assertEq(tribunal.deriveMandateHash(mandate), expectedHash);
    }

    /**
     * @notice Verify that mandate hash derivation works correctly with a different seal value
     * @dev Tests mandate hash derivation with a seal value of 2 to ensure seal uniqueness is reflected
     */
    function test_DeriveMandateHash_DifferentSeal() public view {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            seal: bytes32(uint256(2)),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            recipient: address(0xCAFE),
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18
        });

        bytes32 expectedHash = keccak256(
            abi.encode(
                REFERENCE_MANDATE_TYPEHASH,
                block.chainid,
                address(tribunal),
                uint256(mandate.seal),
                mandate.expires,
                mandate.recipient,
                mandate.token,
                mandate.minimumAmount,
                mandate.baselinePriorityFee,
                mandate.scalingFactor
            )
        );

        assertEq(tribunal.deriveMandateHash(mandate), expectedHash);
    }

    /**
     * @notice Verify that petition reverts when attempting to use an expired mandate
     * @dev Sets up a mandate that has already expired and ensures the petition function reverts
     */
    function test_PetitionRevertsOnExpiredMandate() public {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            seal: bytes32(uint256(1)),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            recipient: address(0xCAFE),
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18
        });

        Tribunal.Compact memory compact = Tribunal.Compact({
            chainId: block.chainid,
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            id: 1,
            maximumAmount: 1 ether,
            sponsorSignature: "",
            allocatorSignature: ""
        });

        compact.sponsorSignature = _generateSponsorSignature(compact, mandate, sponsorPrivateKey);

        Tribunal.Directive memory directive =
            Tribunal.Directive({claimant: address(this), dispensation: 0});

        vm.warp(mandate.expires + 1);

        vm.expectRevert(abi.encodeWithSignature("Expired(uint256)", mandate.expires));
        tribunal.petition(compact, mandate, directive);
    }

    /**
     * @notice Verify that petition reverts when attempting to reuse a seal
     * @dev Tests that a mandate's seal cannot be reused after it has been consumed
     */
    function test_PetitionRevertsOnReusedSeal() public {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            seal: bytes32(uint256(1)),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            recipient: address(0xCAFE),
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18
        });

        Tribunal.Compact memory compact = Tribunal.Compact({
            chainId: block.chainid,
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            id: 1,
            maximumAmount: 1 ether,
            sponsorSignature: "",
            allocatorSignature: ""
        });

        compact.sponsorSignature = _generateSponsorSignature(compact, mandate, sponsorPrivateKey);

        Tribunal.Directive memory directive =
            Tribunal.Directive({claimant: address(this), dispensation: 0});

        tribunal.petition(compact, mandate, directive);

        vm.expectRevert(
            abi.encodeWithSignature("InvalidNonce(address,uint256)", sponsor, uint256(mandate.seal))
        );
        tribunal.petition(compact, mandate, directive);
    }

    /**
     * @notice Verify that disposition correctly identifies used seals
     * @dev Tests that disposition returns true for seals that have been consumed by petition
     */
    function test_DispositionReturnsTrueForUsedSeal() public {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            seal: bytes32(uint256(1)),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            recipient: address(0xCAFE),
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18
        });

        Tribunal.Compact memory compact = Tribunal.Compact({
            chainId: block.chainid,
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            id: 1,
            maximumAmount: 1 ether,
            sponsorSignature: "",
            allocatorSignature: ""
        });

        compact.sponsorSignature = _generateSponsorSignature(compact, mandate, sponsorPrivateKey);

        Tribunal.Directive memory directive =
            Tribunal.Directive({claimant: address(this), dispensation: 0});

        tribunal.petition(compact, mandate, directive);

        assertTrue(tribunal.disposition(sponsor, mandate.seal));
    }

    /**
     * @notice Verify amount derivation with no priority fee above baseline
     * @dev Should return original amounts when priority fee equals baseline
     */
    function test_DeriveAmounts_NoPriorityFee() public {
        uint256 maximumAmount = 100 ether;
        uint256 minimumAmount = 95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 1e18; // 1 WAD, no scaling

        // Set block base fee and priority fee
        vm.fee(baselinePriorityFee);
        vm.txGasPrice(baselinePriorityFee + 1 wei); // Set gas price slightly above base fee

        (uint256 settlementAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(
            settlementAmount,
            minimumAmount,
            "Settlement amount should equal minimum when no priority fee above baseline"
        );
        assertEq(
            claimAmount,
            maximumAmount,
            "Claim amount should equal maximum when no priority fee above baseline"
        );
    }

    /**
     * @notice Verify amount derivation for exact-out case (scaling factor < 1e18)
     * @dev Should keep minimum settlement fixed and scale down maximum claim
     */
    function test_DeriveAmounts_ExactOut() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 5e17; // 0.5 WAD, decreases claim by 50% per priority fee increment

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 2 wei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 2 wei);

        (uint256 settlementAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(
            settlementAmount,
            minimumAmount,
            "Settlement amount should remain at minimum for exact-out"
        );

        // Priority fee above baseline is 2 wei
        // For exact-out with 0.5 WAD scaling factor:
        // scalingMultiplier = 1e18 - ((1e18 - 0.5e18) * 2)
        //                   = 1e18 - (0.5e18 * 2)
        //                   = 1e18 - 1e18
        //                   = 0
        uint256 scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * 2);
        uint256 expectedClaimAmount = maximumAmount.mulWad(scalingMultiplier);
        assertEq(claimAmount, expectedClaimAmount, "Claim amount should go to zero");
    }

    /**
     * @notice Verify amount derivation for exact-in case (scaling factor > 1e18)
     * @dev Should keep maximum claim fixed and scale up minimum settlement
     */
    function test_DeriveAmounts_ExactIn() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 15e17; // 1.5 WAD, increases settlement by 50% per priority fee increment

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 2 wei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 2 wei);

        (uint256 settlementAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(claimAmount, maximumAmount, "Claim amount should remain at maximum for exact-in");

        // Priority fee above baseline is 2 wei
        // For exact-in with 1.5 WAD scaling factor:
        // scalingMultiplier = 1e18 + ((1.5e18 - 1e18) * 2)
        //                   = 1e18 + (0.5e18 * 2)
        //                   = 1e18 + 1e18
        //                   = 2e18
        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 2);
        uint256 expectedSettlementAmount = minimumAmount.mulWadUp(scalingMultiplier);
        assertEq(settlementAmount, expectedSettlementAmount, "Settlement amount should double");
    }

    /**
     * @notice Verify amount derivation with extreme priority fees
     * @dev Should handle large priority fees without overflow
     */
    function test_DeriveAmounts_ExtremePriorityFee() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 15e17; // 1.5 WAD, increases settlement by 50% per priority fee increment

        // Set block base fee lower than priority fee
        uint256 baseFee = 1 gwei;
        vm.fee(baseFee);
        // Set priority fee to baseline + 10 wei
        vm.txGasPrice(baseFee + baselinePriorityFee + 10 wei);

        (uint256 settlementAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(claimAmount, maximumAmount, "Claim amount should remain at maximum for exact-in");

        // Priority fee above baseline is 10 wei
        // For exact-in with 1.5 WAD scaling factor:
        // scalingMultiplier = 1e18 + ((1.5e18 - 1e18) * 10)
        //                   = 1e18 + (0.5e18 * 10)
        //                   = 1e18 + 5e18
        //                   = 6e18
        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 10);
        uint256 expectedSettlementAmount = minimumAmount.mulWadUp(scalingMultiplier);
        assertEq(settlementAmount, expectedSettlementAmount, "Settlement amount should increase 6x");
    }

    function test_DeriveAmounts_RealisticExactIn() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        // 1.0000000001 WAD - 10% increase per gwei above baseline
        uint256 scalingFactor = 1000000000100000000;

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 5 gwei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 5 gwei);

        (uint256 settlementAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(claimAmount, maximumAmount, "Claim amount should remain at maximum for exact-in");

        // Priority fee above baseline is 5 gwei (5e9 wei)
        // For exact-in with 1.0000000001 WAD scaling factor:
        // scalingMultiplier = 1e18 + ((1.0000000001e18 - 1e18) * 5e9)
        //                   = 1e18 + (1e11 * 5e9)
        //                   = 1e18 + 0.5e18
        //                   = 1.5e18
        // So settlement amount increases by 50%
        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 5 gwei);
        uint256 expectedSettlementAmount = minimumAmount.mulWadUp(scalingMultiplier);
        assertEq(
            settlementAmount, expectedSettlementAmount, "Settlement amount should increase by 50%"
        );
    }

    function test_DeriveAmounts_RealisticExactOut() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        // 0.9999999999 WAD - 10% decrease per gwei above baseline
        uint256 scalingFactor = 999999999900000000;

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 5 gwei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 5 gwei);

        (uint256 settlementAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(
            settlementAmount,
            minimumAmount,
            "Settlement amount should remain at minimum for exact-out"
        );

        // Priority fee above baseline is 5 gwei (5e9 wei)
        // For exact-out with 0.9999999999 WAD scaling factor:
        // scalingMultiplier = 1e18 - ((1e18 - 0.9999999999e18) * 5e9)
        //                   = 1e18 - (1e11 * 5e9)
        //                   = 1e18 - 0.5e18
        //                   = 0.5e18
        // So claim amount decreases by 50%
        uint256 scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * 5 gwei);
        uint256 expectedClaimAmount = maximumAmount.mulWad(scalingMultiplier);
        assertEq(claimAmount, expectedClaimAmount, "Claim amount should decrease by 50%");
    }

    function test_PetitionSettlesNativeToken() public {
        // Create a mandate for native token settlement
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            seal: bytes32(uint256(1)),
            expires: uint256(block.timestamp + 1),
            recipient: address(0xBEEF),
            token: address(0),
            minimumAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0
        });

        // Create compact and directive
        Tribunal.Compact memory compact = Tribunal.Compact({
            chainId: block.chainid,
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            id: 1,
            maximumAmount: 1 ether,
            sponsorSignature: "",
            allocatorSignature: ""
        });

        compact.sponsorSignature = _generateSponsorSignature(compact, mandate, sponsorPrivateKey);

        Tribunal.Directive memory directive =
            Tribunal.Directive({claimant: address(this), dispensation: 0});

        // Send ETH with the petition
        uint256 initialSenderBalance = address(this).balance;
        tribunal.petition{value: 2 ether}(compact, mandate, directive);

        // Check that recipient received exactly 1 ETH
        assertEq(address(0xBEEF).balance, 1 ether);
        // Check that sender sent exactly 1 ETH (2 ETH sent - 1 ETH refunded)
        assertEq(initialSenderBalance - address(this).balance, 1 ether);
    }

    function test_PetitionSettlesERC20Token() public {
        // Create a mandate for ERC20 token settlement
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            seal: bytes32(uint256(1)),
            expires: uint256(block.timestamp + 1),
            recipient: address(0xBEEF),
            token: address(token),
            minimumAmount: 100e18,
            baselinePriorityFee: 0,
            scalingFactor: 0
        });

        // Create compact and directive
        Tribunal.Compact memory compact = Tribunal.Compact({
            chainId: block.chainid,
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            id: 1,
            maximumAmount: 1 ether,
            sponsorSignature: "",
            allocatorSignature: ""
        });

        compact.sponsorSignature = _generateSponsorSignature(compact, mandate, sponsorPrivateKey);

        Tribunal.Directive memory directive =
            Tribunal.Directive({claimant: address(this), dispensation: 0});

        // Approve tokens for settlement
        token.approve(address(tribunal), type(uint256).max);

        // Record initial balances
        uint256 initialRecipientBalance = token.balanceOf(address(0xBEEF));
        uint256 initialSenderBalance = token.balanceOf(address(this));

        // Execute petition
        tribunal.petition(compact, mandate, directive);

        // Check that recipient received exactly 100 tokens
        assertEq(token.balanceOf(address(0xBEEF)) - initialRecipientBalance, 100e18);
        // Check that sender sent exactly 100 tokens
        assertEq(initialSenderBalance - token.balanceOf(address(this)), 100e18);
    }

    function test_PetitionRevertsOnInvalidSignature() public {
        // Generate a different private key (not the sponsor's)
        uint256 wrongPK = 0xBEEF;

        // Create mandate and compact
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            seal: bytes32(uint256(1)),
            expires: uint256(block.timestamp + 1),
            recipient: address(0xBEEF),
            token: address(0),
            minimumAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0
        });

        Tribunal.Compact memory compact = Tribunal.Compact({
            arbiter: address(this),
            sponsor: sponsor, // Note: using real sponsor address
            nonce: 0,
            expires: type(uint256).max,
            id: uint256(0),
            maximumAmount: 2 ether,
            chainId: block.chainid,
            sponsorSignature: "",
            allocatorSignature: ""
        });

        // Generate signature with wrong private key
        compact.sponsorSignature = _generateSponsorSignature(compact, mandate, wrongPK);

        Tribunal.Directive memory directive =
            Tribunal.Directive({claimant: address(this), dispensation: 0});

        // Expect revert when using wrong signature
        vm.expectRevert(abi.encodeWithSignature("InvalidSponsorSignature()"));
        tribunal.petition{value: 2 ether}(compact, mandate, directive);
    }

    // Helper function to generate valid sponsor signatures
    function _generateSponsorSignature(
        Tribunal.Compact memory compact,
        Tribunal.Mandate memory mandate,
        uint256 sponsorPK
    ) internal view returns (bytes memory) {
        // First derive the mandate hash
        bytes32 mandateHash = keccak256(
            abi.encode(
                REFERENCE_MANDATE_TYPEHASH,
                block.chainid,
                address(tribunal),
                mandate.seal,
                mandate.expires,
                mandate.recipient,
                mandate.token,
                mandate.minimumAmount,
                mandate.baselinePriorityFee,
                mandate.scalingFactor
            )
        );

        // Then derive the claim hash
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

        // Derive the domain separator
        bytes32 domainSeparator = toCompactDomainSeparator(compact.chainId);

        // Derive the domain hash
        bytes32 domainHash = withDomain(claimHash, domainSeparator);

        // Generate the signature
        (bytes32 r, bytes32 vs) = vm.signCompact(sponsorPK, domainHash);
        return abi.encodePacked(r, vs);
    }

    function toCompactDomainSeparator(uint256 claimChainId)
        internal
        pure
        returns (bytes32 domainSeparator)
    {
        /// @dev `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`.
        bytes32 _DOMAIN_TYPEHASH =
            0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

        /// @dev `keccak256(bytes("The Compact"))`.
        bytes32 _NAME_HASH = 0x5e6f7b4e1ac3d625bac418bc955510b3e054cb6cc23cc27885107f080180b292;

        /// @dev `keccak256("0")`.
        bytes32 _VERSION_HASH = 0x044852b2a670ade5407e78fb2863c51de9fcb96542a07186fe3aeda6bb8a116d;

        address THE_COMPACT = 0x00000000000018DF021Ff2467dF97ff846E09f48;

        assembly ("memory-safe") {
            // Retrieve the free memory pointer.
            let m := mload(0x40)

            // Prepare domain data: EIP-712 typehash, name hash, version hash, notarizing chain ID, and verifying contract.
            mstore(m, _DOMAIN_TYPEHASH)
            mstore(add(m, 0x20), _NAME_HASH)
            mstore(add(m, 0x40), _VERSION_HASH)
            mstore(add(m, 0x60), claimChainId)
            mstore(add(m, 0x80), THE_COMPACT)

            // Derive the domain separator.
            domainSeparator := keccak256(m, 0xa0)
        }
    }

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
}
