# Tribunal ☝️

**Tribunal** is a framework for processing cross-chain swap settlements against PGA (priority gas auction) blockchains. It ensures that tokens are transferred according to the mandate specified by the originating sponsor and enforces that a single party is able to perform the settlement in the event of a dispute.

To settle a cross-chain swap, the filler submits a "fill" request to the Tribunal contract. This consists of three core components:
1. **Claim**: Contains the chain ID of a Compact, its parameters, and its signatures.
2. **Mandate**: Specifies settlement conditions and amount derivation parameters specified by the sponsor.
3. **Claimant**: Specifies the account that will receive the claimed tokens.

> Note for cross-chain message protocols integrating with Tribunal: inherit the `Tribunal` contract and override the `_processDirective` and `_quoteDirective` functions to implement the relevant directive processing logic for passing a message to the arbiter on the claim chain (or ensure that the necessary state is updated to allow for the arbiter to "pull" the message themselves). An ERC7683-compatible implementation is provided in `ERC7683Tribunal.sol`.

### Core Components

#### Claim Structure
```solidity
struct Claim {
    uint256 chainId;          // Claim processing chain ID
    Compact compact;          // The compact parameters
    bytes sponsorSignature;   // Authorization from the sponsor
    bytes allocatorSignature; // Authorization from the allocator
}
```

#### Compact Structure
```solidity
struct Compact {
    address arbiter;          // The account tasked with verifying and submitting the claim
    address sponsor;          // The account to source the tokens from
    uint256 nonce;            // A parameter to enforce replay protection, scoped to allocator
    uint256 expires;          // The time at which the claim expires
    uint256 id;               // The token ID of the ERC6909 token to allocate
    uint256 amount;           // The amount of ERC6909 tokens to allocate
}
```

#### Mandate Structure
```solidity
struct Mandate {
    address recipient;           // Recipient of filled tokens
    uint256 expires;             // Mandate expiration timestamp
    address token;               // Fill token (address(0) for native)
    uint256 minimumAmount;       // Minimum fill amount
    uint256 baselinePriorityFee; // Base fee threshold where scaling kicks in
    uint256 scalingFactor;       // Fee scaling multiplier (1e18 baseline)
    bytes32 salt;                // Preimage resistance parameter
}
```

### Process Flow

1. Fillers initiate by calling `fill(Claim calldata claim, Mandate calldata mandate, address claimant)` and providing any msg.value required for the settlement to pay to process the cross-chain message.
2. Tribunal verifies that the mandate has not expired by checking the mandate's `expires` timestamp
3. Computation phase:
   - Derives `mandateHash` using an EIP712 typehash for the mandate, destination chainId, tribunal address, and mandate data
   - Derives `claimHash` using an EIP712 typehash for the compact with the mandate as a witness and the compact data including the `mandateHash`
   - Ensures that the `claimHash` has not already been used and marks it as filled
   - Calculates `fillAmount` and `claimAmount` based on:
     - Compact `amount`
     - Mandate parameters (`minimumAmount`, `baselinePriorityFee`, `scalingFactor`)
     - `tx.gasprice` and `block.basefee`
     - NOTE: `scalingFactor` will result in an increased `fillAmount` if `> 1e18` or a decreased `claimAmount` if `< 1e18`
     - NOTE: `scalingFactor` is combined with `tx.gasprice - (block.basefee + baselinePriorityFee)` (or 0 if it would otherwise be negative) before being applied to the amount
4. Execution phase:
   - Transfers `fillAmount` of `token` to mandate `recipient`
   - Processes directive via `_processDirective(chainId, compact, sponsorSignature, allocatorSignature, mandateHash, claimant, claimAmount)`

There are also a few view functions:
 - `quote(Claim calldata claim, Mandate calldata mandate, address claimant)` will suggest a dispensation amount (function of gas on claim chain + any additional "protocol overhead" if using push-based cross-chain messaging)
 - `filled(bytes32 claimHash)` will check if a given claim hash has already been filled (used)
 - `getCompactWitnessDetails()` will return the Mandate witness typestring and that correlates token + amount arguments (so frontends can show context about the token and use decimal inputs)
 - `deriveMandateHash(Mandate calldata mandate)` will return the EIP712 typehash for the mandate
 - `deriveClaimHash(Compact calldata compact, bytes32 mandateHash)` will return the unique claim hash for a compact and mandate combination
 - `deriveAmounts(uint256 maximumAmount, uint256 minimumAmount, uint256 baselinePriorityFee, uint256 scalingFactor)` will return the fill and claim amounts based on the parameters; the base fee and priority fee will be applied to the amount and so should be tuned in the call appropriately

#### Mandate EIP-712 Typehash
This is what swappers will see as their witness data when signing a `Compact`:
```solidity
struct Mandate {
    uint256 chainId;
    address tribunal;
    address recipient;
    uint256 expires;
    address token;
    uint256 minimumAmount;
    uint256 baselinePriorityFee;
    uint256 scalingFactor;
    bytes32 salt;
}
```

### ERC7683 Integration

The `ERC7683Tribunal` contract implements the `IDestinationSettler` interface from ERC7683, allowing for standardized cross-chain settlement:

```solidity
interface IDestinationSettler {
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external;
}
```

This implementation allows the Tribunal to be used with any ERC7683-compatible cross-chain messaging system.

## Remaining Work
- [ ] Create CI/CD pipeline
- [ ] Implement directive processing with cross-chain messaging
- [ ] Improve quote function for gas estimation
- [ ] Set up comprehensive test suite
- [ ] Add tests for fee-on-transfer tokens
- [ ] Add tests for quote function
- [ ] Add tests for witness details
- [ ] Add tests for directive processing
- [ ] Develop integration tests
- [ ] Create deployment scripts

## Test Cases

### Core Functionality
- [X] Fill submission
- [X] Claim hash derivation
- [X] Expiration checking
- [X] Hash derivation
- [X] Amount calculations
- [X] Token transfers
- [ ] Quote function
- [ ] Witness details
- [ ] Directive processing

### Edge Cases
- [X] Zero amounts
- [X] Native token handling
- [X] Invalid claim hashes
- [X] Expired mandates
- [X] Gas price edge cases
- [X] Scale factor boundaries
- [ ] Fee-on-transfer tokens
- [ ] Cross-chain message failures
- [ ] Maximum gas price scenarios

### Security
- [X] Replay protection
- [X] Access control
- [X] Input validation
- [X] Integer overflow/underflow
- [ ] Cross-chain message security
- [ ] Gas estimation attack vectors

### Reentrancy
Reentrancy protection is not needed in the current design as it follows the checks-effects-interactions pattern and never holds tokens. The contract consumes nonces before any external calls and uses a pull pattern for token transfers.

### Fee-on-Transfer Token Handling
Swappers must handle fee-on-transfer tokens carefully, as settlement will result in fewer tokens being received by the recipient than the specified fill amount. When providing fill amounts for such tokens:
- Swappers must account for the token's transfer fee in their calculations
- The actual received amount will be less than the specified fill amount
- Frontend implementations should display appropriate warnings
- Consider implementing additional safety checks or multipliers (though this also complicates matters for fillers)

## Future Work
* Additional amount derivation functions (eg reverse dutch)
* Multi-token settlement support
* Batch processing capabilities
* Cross-chain message optimization
* Advanced dispute resolution mechanisms
* Gas optimization improvements

## Usage

```shell
$ git clone https://github.com/uniswap/tribunal
$ forge install
```

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot --isolate
```

### Code Coverage
```shell
$ forge coverage
```

### Deploy

```shell
$ forge script script/Tribunal.s.sol:TribunalScript --rpc-url <your_rpc_url> --private-key <your_private_key>
