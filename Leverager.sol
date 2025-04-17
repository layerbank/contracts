// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./interfaces/ILeverager.sol";
import "./interfaces/IBEP20.sol";
import "./interfaces/ILToken.sol";
import "./interfaces/ICore.sol";

import "./library/SafeToken.sol";
import "./library/Constant.sol";

contract Leverager is ILeverager, Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeToken for address;

    uint256 public constant RATIO_DIVISOR = 10000;

    ICore public core;

    address public lETH;

    // initializer
    bool public initialized;

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    constructor() public {}

    modifier onlyListedMarket(address lToken) {
        Constant.MarketInfo memory marketInfo = core.marketInfoOf(lToken);
        require(marketInfo.isListed, "Leverager: invalid market");
        _;
    }

    function initialize(ICore _core, address _lETH) external onlyOwner {
        require(initialized == false, "already initialized");
        require(address(_core) != address(0), "Not a valid address");
        require(_lETH != address(0), "Not a valid address");

        core = _core;
        lETH = _lETH;

        initialized = true;
    }

    /**
     * @dev Loop the deposit and borrow of an asset
     * @param lToken for loop
     * @param amount for the initial deposit
     * @param borrowRatio Ratio of tokens to borrow
     * @param loopCount Repeat count for loop
     * @param isBorrow true when the loop without deposit tokens
     **/
    function loop(
        address lToken,
        uint256 amount,
        uint256 borrowRatio,
        uint256 loopCount,
        bool isBorrow
    ) external onlyListedMarket(lToken) {
        require(borrowRatio <= RATIO_DIVISOR, "Invalid ratio");
        address asset = ILToken(lToken).underlying();

        // true when the loop without deposit tokens
        if (!isBorrow) {
            asset.safeTransferFrom(msg.sender, address(this), amount);
        }
        if (IBEP20(asset).allowance(address(this), lToken) == 0) {
            asset.safeApprove(address(lToken), uint256(-1));
        }
        if (IBEP20(asset).allowance(address(this), address(core)) == 0) {
            asset.safeApprove(address(core), uint256(-1));
        }

        if (!isBorrow) {
            core.supplyBehalf(msg.sender, lToken, amount);
        }

        for (uint256 i = 0; i < loopCount; i++) {
            amount = amount.mul(borrowRatio).div(RATIO_DIVISOR);
            core.borrowBehalf(msg.sender, lToken, amount);
            core.supplyBehalf(msg.sender, lToken, amount);
        }
    }

    function loopETH(uint256 borrowRatio, uint256 loopCount) external payable {
        require(borrowRatio <= RATIO_DIVISOR, "Invalid ratio");
        uint256 amount = msg.value;

        core.supplyBehalf{value: amount}(msg.sender, lETH, 0);

        for (uint256 i = 0; i < loopCount; i++) {
            amount = amount.mul(borrowRatio).div(RATIO_DIVISOR);
            core.borrowBehalf(msg.sender, lETH, amount);
            core.supplyBehalf{value: amount}(msg.sender, lETH, 0);
        }
    }
}
