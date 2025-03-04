// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDestinationSettler} from "./Interfaces/IDestinationSettler.sol";
import {Tribunal} from "./Tribunal.sol";

/// @title ERC7683Tribunal
/// @notice A contract that enables the tribunal compatibility with the ERC7683 destination settler interface
contract ERC7683Tribunal is Tribunal, IDestinationSettler {
    // ======== Constructor ========
    constructor() {}

    // ======== External Functions ========
    function fill(bytes32, bytes calldata originData, bytes calldata fillerData) external {
        (Claim memory claim, Mandate memory mandate) = abi.decode(originData, (Claim, Mandate));
        address claimant = abi.decode(fillerData, (address));

        _fill(claim, mandate, claimant);
    }

    function quote(bytes32, bytes calldata originData, bytes calldata fillerData)
        external
        view
        returns (uint256 dispensation)
    {
        (Claim memory claim, Mandate memory mandate) = abi.decode(originData, (Claim, Mandate));
        address claimant = abi.decode(fillerData, (address));

        return _quote(claim, mandate, claimant);
    }
}
