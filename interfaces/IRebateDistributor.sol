// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;

interface IRebateDistributor {
    function setKeeper(address _keeper) external;

    function pause() external;

    function unpause() external;

    function updateAdminFeeRate(uint256 newAdminFeeRate) external;

    function checkpoint() external;

    function weeklyRebatePool() external view returns (uint256);

    function weeklyProfitOfVP(uint256 vp) external view returns (uint256);

    function weeklyProfitOf(address account) external view returns (uint256);

    function indicativeAPR() external view returns (uint256);

    function indicativeAPROf(uint256 amount, uint256 lockDuration) external view returns (uint256);

    function indicativeAPROfUser(address account) external view returns (uint256);

    function accruedRebates(address account) external view returns (uint256, uint256, uint256[] memory);

    function claimRebates() external returns (uint256, uint256, uint256[] memory);

    function claimAdminRebates() external returns (uint256, uint256[] memory);

    function addLABToRebatePool(uint256 amount) external;

    function addMarketUTokenToRebatePool(address lToken, uint256 uAmount) external payable;
}
