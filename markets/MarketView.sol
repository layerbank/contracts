// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../library/Constant.sol";
import "../interfaces/IBEP20.sol";
import "../interfaces/IValidator.sol";
import "../interfaces/IRateModel.sol";
import "../interfaces/ILToken.sol";
import "../interfaces/ICore.sol";
import "../interfaces/IMarketView.sol";

contract MarketView is IMarketView, Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    mapping(address => IRateModel) public rateModel;

    /* ========== INITIALIZER ========== */

    constructor() public {}

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setRateModel(address lToken, address _rateModel) public onlyOwner {
        require(_rateModel != address(0), "MarketView: invalid rate model address");
        rateModel[lToken] = IRateModel(_rateModel);
    }

    /* ========== VIEWS ========== */

    function borrowRatePerSec(address lToken) public view override returns (uint256) {
        Constant.AccrueSnapshot memory snapshot = pendingAccrueSnapshot(ILToken(lToken));
        return rateModel[lToken].getBorrowRate(ILToken(lToken).getCash(), snapshot.totalBorrow, snapshot.totalReserve);
    }

    function supplyRatePerSec(address lToken) public view override returns (uint256) {
        Constant.AccrueSnapshot memory snapshot = pendingAccrueSnapshot(ILToken(lToken));
        return
            rateModel[lToken].getSupplyRate(
                ILToken(lToken).getCash(),
                snapshot.totalBorrow,
                snapshot.totalReserve,
                ILToken(lToken).reserveFactor()
            );
    }

    function supplyAPR(address lToken) external view override returns (uint256) {
        return supplyRatePerSec(lToken).mul(365 days);
    }

    function borrowAPR(address lToken) external view override returns (uint256) {
        return borrowRatePerSec(lToken).mul(365 days);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function pendingAccrueSnapshot(ILToken lToken) internal view returns (Constant.AccrueSnapshot memory) {
        Constant.AccrueSnapshot memory snapshot;
        snapshot.totalBorrow = lToken._totalBorrow();
        snapshot.totalReserve = lToken.totalReserve();
        snapshot.accInterestIndex = lToken.accInterestIndex();

        uint256 reserveFactor = lToken.reserveFactor();
        uint256 lastAccruedTime = lToken.lastAccruedTime();

        if (block.timestamp > lastAccruedTime && snapshot.totalBorrow > 0) {
            uint256 borrowRate = rateModel[address(lToken)].getBorrowRate(
                lToken.getCash(),
                snapshot.totalBorrow,
                snapshot.totalReserve
            );
            uint256 interestFactor = borrowRate.mul(block.timestamp.sub(lastAccruedTime));
            uint256 pendingInterest = snapshot.totalBorrow.mul(interestFactor).div(1e18);

            snapshot.totalBorrow = snapshot.totalBorrow.add(pendingInterest);
            snapshot.totalReserve = snapshot.totalReserve.add(pendingInterest.mul(reserveFactor).div(1e18));
            snapshot.accInterestIndex = snapshot.accInterestIndex.add(
                interestFactor.mul(snapshot.accInterestIndex).div(1e18)
            );
        }
        return snapshot;
    }
}
