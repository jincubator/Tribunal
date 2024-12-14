// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Tribunal} from "../src/Tribunal.sol";

contract TribunalScript is Script {
    function run() public {
        vm.broadcast();
        new Tribunal();
    }
}
