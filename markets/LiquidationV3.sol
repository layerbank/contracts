// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

import "../library/SafeToken.sol";
import "../library/Whitelist.sol";

import "../interfaces/ICore.sol";
import "../interfaces/ILToken.sol";
import "../interfaces/IPriceCalculator.sol";
import "../interfaces/IFlashLoanReceiver.sol";
import "../interfaces/IPool.sol";
import "../interfaces/ISwapRouter.sol";

contract LiquidationV3 is IFlashLoanReceiver, Whitelist, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeToken for address;

    struct FlashLoanParam {
        address lTokenBorrowed;
        address underlyingBorrowed;
        address lTokenCollateral;
        address borrower;
        uint256 amount;
    }

    /* ========== CONSTANTS ============= */

    address private constant ETH = address(0);
    address private constant WETH = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    address private constant WBTC = address(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    address private constant DAI = address(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);
    address private constant USDT = address(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
    address private constant USDC = address(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    address private constant ARB = address(0x912CE59144191C1204E64559FE8253a0e49E6548);

    ISwapRouter private constant router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IPool private constant lendPool = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    /* ========== STATE VARIABLES ========== */

    mapping(address => mapping(address => bool)) private tokenApproval;
    mapping(address => mapping(address => uint24)) private pools;
    mapping(address => address) private flashLoanTokens;
    ICore public core;
    IPriceCalculator public priceCalculator;

    // initializer
    bool public initialized;

    receive() external payable {}

    /* ========== Event ========== */

    event Liquidated(
        address lTokenBorrowed,
        address lTokenCollateral,
        address borrower,
        uint256 amount,
        uint256 rebateAmount
    );

    /* ========== INITIALIZER ========== */

    constructor() public {}

    function initialize(address _core, address _priceCalculator) external onlyOwner {
        require(initialized == false, "already initialized");
        require(_core != address(0), "Liquidation: core address can't be zero");
        require(_priceCalculator != address(0), "Liquidation: priceCalculator address can't be zero");

        core = ICore(_core);
        priceCalculator = IPriceCalculator(_priceCalculator);

        _approveTokens();
        _addPools();
        _initFlashLoanTokens();

        initialized = true;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function liquidate(
        address lTokenBorrowed,
        address lTokenCollateral,
        address borrower,
        uint256 amount
    ) external onlyWhitelisted nonReentrant {
        (uint256 collateralInUSD, , uint256 borrowInUSD) = core.accountLiquidityOf(borrower);
        require(borrowInUSD > collateralInUSD, "Liquidation: Insufficient shortfall");

        _flashLoan(lTokenBorrowed, lTokenCollateral, borrower, amount);

        address underlying = ILToken(lTokenBorrowed).underlying();

        emit Liquidated(
            lTokenBorrowed,
            lTokenCollateral,
            borrower,
            amount,
            underlying == ETH
                ? address(this).balance
                : IERC20(ILToken(lTokenBorrowed).underlying()).balanceOf(address(this))
        );

        _sendTokenToRebateDistributor(underlying);
    }

    /// @notice Liquidate borrower's max value debt using max value collateral
    /// @param borrower borrower account address
    function autoLiquidate(address borrower) external onlyWhitelisted nonReentrant {
        (uint256 collateralInUSD, , uint256 borrowInUSD) = core.accountLiquidityOf(borrower);
        require(borrowInUSD > collateralInUSD, "Liquidation: Insufficient shortfall");

        (address lTokenBorrowed, address lTokenCollateral) = _getTargetMarkets(borrower);
        uint256 liquidateAmount = _getMaxLiquidateAmount(lTokenBorrowed, lTokenCollateral, borrower);
        require(liquidateAmount > 0, "Liquidation: liquidate amount error");

        _flashLoan(lTokenBorrowed, lTokenCollateral, borrower, liquidateAmount);

        address underlying = ILToken(lTokenBorrowed).underlying();

        emit Liquidated(
            lTokenBorrowed,
            lTokenCollateral,
            borrower,
            liquidateAmount,
            underlying == ETH
                ? address(this).balance
                : IERC20(ILToken(lTokenBorrowed).underlying()).balanceOf(address(this))
        );

        _sendTokenToRebateDistributor(underlying);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function liquidateInfo(address borrower) external view returns (uint256, uint256, address, address, uint256) {
        (uint256 collateralInUSD, , uint256 borrowInUSD) = core.accountLiquidityOf(borrower);
        require(borrowInUSD > collateralInUSD, "Liquidation: Insufficient shortfall");

        (address lTokenBorrowed, address lTokenCollateral) = _getTargetMarkets(borrower);
        uint256 liquidateAmount = _getMaxLiquidateAmount(lTokenBorrowed, lTokenCollateral, borrower);
        require(liquidateAmount > 0, "Liquidation: liquidate amount error");

        return (collateralInUSD, borrowInUSD, lTokenBorrowed, lTokenCollateral, liquidateAmount);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _approveTokens() private {
        address[] memory markets = core.allMarkets();

        for (uint256 i = 0; i < markets.length; i++) {
            address token = ILToken(markets[i]).underlying();
            _approveToken(token, address(markets[i]));
            _approveToken(token, address(router));
            _approveToken(token, address(lendPool));
        }
        _approveToken(WETH, address(router));
        _approveToken(WETH, address(lendPool));
    }

    function _approveToken(address token, address spender) private {
        if (token != ETH && !tokenApproval[token][spender]) {
            token.safeApprove(spender, uint256(-1));
            tokenApproval[token][spender] = true;
        }
    }

    function _addPools() private {
        _addPool(WETH, ARB, 500);
        _addPool(WETH, USDC, 500);
        _addPool(WETH, USDT, 500);
        _addPool(WETH, WBTC, 500);
        _addPool(DAI, USDC, 500);
        _addPool(USDT, USDC, 100);
        _addPool(ARB, USDC, 3000);
        _addPool(ARB, USDT, 3000);
    }

    function _initFlashLoanTokens() private {
        flashLoanTokens[ARB] = WETH;
    }

    function _flashLoan(address lTokenBorrowed, address lTokenCollateral, address borrower, uint256 amount) private {
        address underlying = ILToken(lTokenBorrowed).underlying();
        address asset = underlying == ETH ? WETH : underlying;

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes = new uint256[](1);
        bytes memory params = abi.encode(
            FlashLoanParam(lTokenBorrowed, underlying, lTokenCollateral, borrower, amount)
        );

        assets[0] = _getFlashLoanToken(asset);
        amounts[0] = assets[0] == WETH && asset != WETH ? _getETHAmountOfEqualValue(lTokenBorrowed, amount) : amount;
        modes[0] = 0;

        lendPool.flashLoan(address(this), assets, amounts, modes, address(this), params, 0);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(lendPool), "Liquidation: Invalid sender");
        require(initiator == address(this), "Liquidation Invalid initiator");
        require(assets.length == 1, "Liquidation: Invalid assets");
        require(amounts.length == 1, "Liquidation: Invalid amounts");
        require(premiums.length == 1, "Liquidation: Invalid premiums");
        FlashLoanParam memory param = abi.decode(params, (FlashLoanParam));

        if (param.underlyingBorrowed != assets[0] && param.underlyingBorrowed != ETH) {
            _swapForLiquidate(assets[0], param.underlyingBorrowed, 0);
        } else if (assets[0] == WETH && param.underlyingBorrowed == ETH) {
            IWETH(WETH).withdraw(amounts[0]);
        }

        _liquidate(param.lTokenBorrowed, param.lTokenCollateral, param.borrower, param.amount);

        if (ILToken(param.lTokenCollateral).underlying() == ETH) {
            IWETH(WETH).deposit{value: address(this).balance}();
        }

        _swapForRepay(param.lTokenCollateral, assets[0], amounts[0].add(premiums[0]));

        return true;
    }

    function _liquidate(address lTokenBorrowed, address lTokenCollateral, address borrower, uint256 amount) private {
        if (ILToken(lTokenBorrowed).underlying() == ETH) {
            core.liquidateBorrow{value: amount}(lTokenBorrowed, lTokenCollateral, borrower, 0);
        } else {
            core.liquidateBorrow(lTokenBorrowed, lTokenCollateral, borrower, amount);
        }

        uint256 lTokenCollateralBalance = ILToken(lTokenCollateral).balanceOf(address(this));
        _redeemToken(lTokenCollateral, lTokenCollateralBalance);
    }

    function _getFlashLoanToken(address token) private view returns (address) {
        if (flashLoanTokens[token] == address(0)) {
            return token;
        }

        return flashLoanTokens[token];
    }

    function _getTargetMarkets(
        address account
    ) private view returns (address lTokenBorrowed, address lTokenCollateral) {
        uint256 maxSupplied;
        uint256 maxBorrowed;
        address[] memory markets = core.marketListOf(account);
        uint256[] memory prices = priceCalculator.getUnderlyingPrices(markets);

        for (uint256 i = 0; i < markets.length; i++) {
            uint256 borrowAmount = ILToken(markets[i]).borrowBalanceOf(account);
            uint256 supplyAmount = ILToken(markets[i]).underlyingBalanceOf(account);

            uint256 borrowValue = prices[i].mul(borrowAmount).div(10 ** _getDecimals(markets[i]));
            uint256 supplyValue = prices[i].mul(supplyAmount).div(10 ** _getDecimals(markets[i]));

            if (borrowValue > 0 && borrowValue > maxBorrowed) {
                maxBorrowed = borrowValue;
                lTokenBorrowed = markets[i];
            }

            uint256 collateralFactor = core.marketInfoOf(markets[i]).collateralFactor;
            if (collateralFactor > 0 && supplyValue > 0 && supplyValue > maxSupplied) {
                maxSupplied = supplyValue;
                lTokenCollateral = markets[i];
            }
        }
    }

    function _getMaxLiquidateAmount(
        address lTokenBorrowed,
        address lTokenCollateral,
        address borrower
    ) private view returns (uint256 liquidateAmount) {
        uint256 borrowPrice = priceCalculator.getUnderlyingPrice(lTokenBorrowed);
        uint256 supplyPrice = priceCalculator.getUnderlyingPrice(lTokenCollateral);
        require(supplyPrice != 0 && borrowPrice != 0, "Liquidation: price error");

        uint256 borrowAmount = ILToken(lTokenBorrowed).borrowBalanceOf(borrower);
        uint256 supplyAmount = ILToken(lTokenCollateral).underlyingBalanceOf(borrower);

        uint256 borrowValue = borrowPrice.mul(borrowAmount).div(10 ** _getDecimals(lTokenBorrowed));
        uint256 supplyValue = supplyPrice.mul(supplyAmount).div(10 ** _getDecimals(lTokenCollateral));

        uint256 liquidationIncentive = core.liquidationIncentive();
        uint256 maxCloseValue = borrowValue.mul(core.closeFactor()).div(1e18);
        uint256 maxCloseValueWithIncentive = maxCloseValue.mul(liquidationIncentive).div(1e18);

        liquidateAmount = maxCloseValueWithIncentive < supplyValue
            ? maxCloseValue.mul(1e18).div(borrowPrice).div(10 ** (18 - _getDecimals(lTokenBorrowed)))
            : supplyValue.mul(1e36).div(liquidationIncentive).div(borrowPrice).div(
                10 ** (18 - _getDecimals(lTokenBorrowed))
            );
    }

    function _redeemToken(address lToken, uint256 lAmount) private {
        core.redeemToken(lToken, lAmount);
    }

    function _sendTokenToRebateDistributor(address token) private {
        address rebateDistributor = core.rebateDistributor();
        uint256 balance = token == ETH ? address(this).balance : IERC20(token).balanceOf(address(this));

        if (balance > 0 && token == ETH) {
            SafeToken.safeTransferETH(rebateDistributor, balance);
        } else if (balance > 0) {
            token.safeTransfer(rebateDistributor, balance);
        }
    }

    function _swapForLiquidate(address fromToken, address toToken, uint256 minReceiveAmount) private returns (uint256) {
        uint256 fromTokenBalance = IERC20(fromToken).balanceOf(address(this));
        if (toToken == ETH) {
            toToken = WETH;
        }
        return _swapToken(fromToken, fromTokenBalance, toToken, minReceiveAmount);
    }

    function _swapForRepay(address lTokenCollateral, address underlyingBorrowed, uint256 minReceiveAmount) private {
        address collateralToken = ILToken(lTokenCollateral).underlying();
        if (collateralToken == ETH) {
            collateralToken = WETH;
        }
        if (underlyingBorrowed == ETH) {
            underlyingBorrowed = WETH;
        }

        uint256 collateralTokenAmount = IERC20(collateralToken).balanceOf(address(this));
        require(collateralTokenAmount > 0, "Liquidation: Insufficent collateral for repay swap");

        _swapToken(collateralToken, collateralTokenAmount, underlyingBorrowed, minReceiveAmount);
    }

    function _swapToken(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMinimum
    ) private returns (uint256 amountOut) {
        if (tokenIn != tokenOut) {
            ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
                path: _getSwapPath(tokenIn, tokenOut),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum
            });

            amountOut = router.exactInput(params);
        }
    }

    function _getSwapPath(address tokenIn, address tokenOut) private view returns (bytes memory) {
        if (tokenIn == ETH) {
            tokenIn = WETH;
        }
        if (tokenOut == ETH) {
            tokenOut = WETH;
        }

        if (pools[tokenIn][tokenOut] > 0) {
            return abi.encodePacked(tokenIn, pools[tokenIn][tokenOut], tokenOut);
        }

        if (tokenIn != WETH && tokenOut != WETH && pools[tokenIn][WETH] > 0 && pools[WETH][tokenOut] > 0) {
            return abi.encodePacked(tokenIn, pools[tokenIn][WETH], WETH, pools[WETH][tokenOut], tokenOut);
        }

        if (tokenIn != USDC && tokenOut != USDC && pools[tokenIn][USDC] > 0 && pools[USDC][tokenOut] > 0) {
            return abi.encodePacked(tokenIn, pools[tokenIn][USDC], USDC, pools[USDC][tokenOut], tokenOut);
        }

        if (tokenIn != USDT && tokenOut != USDT && pools[tokenIn][USDT] > 0 && pools[USDT][tokenOut] > 0) {
            return abi.encodePacked(tokenIn, pools[tokenIn][USDT], USDT, pools[USDT][tokenOut], tokenOut);
        }

        if (tokenIn != ARB && tokenOut != ARB && pools[tokenIn][ARB] > 0 && pools[ARB][tokenOut] > 0) {
            return abi.encodePacked(tokenIn, pools[tokenIn][ARB], ARB, pools[ARB][tokenOut], tokenOut);
        }

        if (tokenIn == WBTC && tokenOut == DAI) {
            return abi.encodePacked(WBTC, pools[WBTC][WETH], WETH, pools[WETH][USDC], USDC, pools[USDC][DAI], DAI);
        }

        if (tokenIn == DAI && tokenIn == WBTC) {
            return abi.encodePacked(DAI, pools[DAI][USDC], USDC, pools[USDC][WETH], WETH, pools[WETH][WBTC]);
        }

        revert("Liquidation: path error");
    }

    function _addPool(address token0, address token1, uint24 fee) private {
        pools[token0][token1] = fee;
        pools[token1][token0] = fee;
    }

    function _getETHAmountOfEqualValue(address lToken, uint256 amount) private view returns (uint256 ethAmount) {
        uint256 ethPrice = priceCalculator.priceOfETH();
        uint256 tokenPrice = priceCalculator.getUnderlyingPrice(lToken);

        ethAmount = amount.mul((10 ** (18 - _getDecimals(lToken)))).mul(tokenPrice.mul(1e18).div(ethPrice)).div(1e18);
    }

    function _getDecimals(address lToken) private view returns (uint256 decimals) {
        address underlying = ILToken(lToken).underlying();
        if (underlying == address(0)) {
            decimals = 18;
        } else {
            decimals = IERC20(underlying).decimals();
        }
    }
}
