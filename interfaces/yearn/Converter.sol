// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

interface Converter {
    function convert(address) external returns (uint256);
}
