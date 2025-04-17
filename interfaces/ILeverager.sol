// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface ILeverager {
    event FeePercentUpdated(uint256 _feePercent);
    event TreasuryUpdated(address indexed _treasury);
}
