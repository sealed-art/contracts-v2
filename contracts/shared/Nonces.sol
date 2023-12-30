pragma solidity ^0.8.4;

import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

abstract contract Nonces {
    mapping(address => uint256) public accountCounter;

    event CounterIncreased(address account, uint256 newCounter);

    function increaseCounter(uint256 newCounter) external {
        require(newCounter > accountCounter[msg.sender], "too low");
        accountCounter[msg.sender] = newCounter;
        emit CounterIncreased(msg.sender, newCounter);
    }
}