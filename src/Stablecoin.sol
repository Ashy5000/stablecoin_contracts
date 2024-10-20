// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Stablecoin is ERC20 {
    IERC20 public usdc = IERC20(0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8);

    constructor() ERC20("Unistable", "UUSD") {}

    function wrap(uint256 amount) public {
        usdc.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }

    function unwrap(uint256 amount) public {
        _burn(msg.sender, amount);
        usdc.transfer(msg.sender, amount);
    }
}
