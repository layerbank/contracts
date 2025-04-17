// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface ISaleLabOverflowFarm {
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        bool claimed; // default false
        uint256 rewardDebt;
    }

    event Deposit(address indexed user, uint256 amount, address referral);
    event Harvest(address indexed user, uint256 offeringAmount, uint256 excessAmount);

    function deposit(address _referral) external payable;
    function harvest() external;
    function harvestOverflowReward() external;
    function harvestVestingTokens() external;

    function getOfferingAmount(address _user) external view returns (uint256);
    function getRefundingAmount(address _user) external view returns (uint256);
    function getUserAllocation(address _user) external view returns (uint256);
    function hasHarvest(address _user) external view returns (bool);
    function tokensClaimable(address _user) external view returns (uint256 claimableAmount);

    function pendingReward(address _user) external view returns (uint256);
    function getAddressListLength() external view returns (uint256);
    function rewardPerSecond() external view returns (uint256);

    function startTime() external view returns (uint256);
    function endTime() external view returns (uint256);
    function harvestTimestamp() external view returns (uint256);
    function raisingAmount() external view returns (uint256);
    function offeringAmount() external view returns (uint256);
    function totalAmount() external view returns (uint256);

    function userInfo(address user) external view returns (uint256, bool, uint256);
    function whitelist(address user) external view returns (bool);
}
