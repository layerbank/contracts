// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../library/Constant.sol";

interface ILABDistributor {
    /* ========== EVENTS ========== */
    event DistributionSpeedUpdated(
        address indexed gToken,
        uint256 supplySpeed,
        uint256 borrowSpeed
    );
    event Claimed(address indexed user, uint256 amount);
    event Compound(address indexed user, uint256 amount);

    function accuredLAB(
        address[] calldata markets,
        address account
    ) external view returns (uint);

    function distributionInfoOf(
        address market
    ) external view returns (Constant.DistributionInfo memory);

    function accountDistributionInfoOf(
        address market,
        address account
    ) external view returns (Constant.DistributionAccountInfo memory);

    function apyDistributionOf(
        address market,
        address account
    ) external view returns (Constant.DistributionAPY memory);

    function boostedRatioOf(
        address market,
        address account
    ) external view returns (uint boostedSupplyRatio, uint boostedBorrowRatio);

    function notifySupplyUpdated(address market, address user) external;

    function notifyBorrowUpdated(address market, address user) external;

    function notifyTransferred(
        address qToken,
        address sender,
        address receiver
    ) external;

    function claim(address[] calldata markets, address account) external;

    function kick(address user) external;

    function updateAccountBoostedInfo(address user) external;

    function compound(address[] calldata markets, address account) external;

    function pause() external;

    function unpause() external;

    function approve(address _spender, uint256 amount) external returns (bool);
}
