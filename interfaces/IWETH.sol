// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;

interface IWETH {
    function approve(address spender, uint256 value) external returns (bool);

    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);

    function deposit() external payable;

    function withdraw(uint256 amount) external;
}
