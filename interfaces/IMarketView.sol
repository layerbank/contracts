// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../library/Constant.sol";

interface IMarketView {
    function borrowRatePerSec(address lToken) external view returns (uint256);

    function supplyRatePerSec(address lToken) external view returns (uint256);

    function supplyAPR(address lToken) external view returns (uint256);

    function borrowAPR(address lToken) external view returns (uint256);
}
