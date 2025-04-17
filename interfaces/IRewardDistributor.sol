// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;

interface IRewardDistributor {
    function withdrawTokens() external;
    function tokensClaimable(address _user) external view returns (uint256 claimableAmount);
}
