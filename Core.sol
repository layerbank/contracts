// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "./CoreAdmin.sol";

import "./interfaces/ILToken.sol";
import "./interfaces/IValidator.sol";
import "./interfaces/IPriceCalculator.sol";

contract Core is CoreAdmin {
    using SafeMath for uint256;

    /* ========== CONSTANT VARIABLES ========== */

    address internal constant ETH = 0x0000000000000000000000000000000000000000;

    /* ========== STATE VARIABLES ========== */

    mapping(address => address[]) public marketListOfUsers; // (account => lTokenAddress[])
    mapping(address => mapping(address => bool)) public usersOfMarket; // (lTokenAddress => (account => joined))

    // initializer
    bool public initialized;

    /* ========== INITIALIZER ========== */

    constructor() public {}

    function initialize(address _priceCalculator) external onlyOwner {
        require(initialized == false, "already initialized");

        __Core_init();
        priceCalculator = IPriceCalculator(_priceCalculator);

        initialized = true;
    }

    /* ========== MODIFIERS ========== */

    modifier onlyMemberOfMarket(address lToken) {
        require(usersOfMarket[lToken][msg.sender], "Core: must enter market");
        _;
    }

    modifier onlyMarket() {
        bool fromMarket = false;
        for (uint256 i = 0; i < markets.length; i++) {
            if (msg.sender == markets[i]) {
                fromMarket = true;
                break;
            }
        }
        require(fromMarket == true, "Core: caller should be market");
        _;
    }

    modifier onlyLeverager() {
        require(msg.sender == leverager, "Core: caller should be leverager");
        _;
    }

    /* ========== VIEWS ========== */

    function allMarkets() external view override returns (address[] memory) {
        return markets;
    }

    function marketInfoOf(address lToken) external view override returns (Constant.MarketInfo memory) {
        return marketInfos[lToken];
    }

    function marketListOf(address account) external view override returns (address[] memory) {
        return marketListOfUsers[account];
    }

    function checkMembership(address account, address lToken) external view override returns (bool) {
        return usersOfMarket[lToken][account];
    }

    function accountLiquidityOf(
        address account
    ) external view override returns (uint256 collateralInUSD, uint256 supplyInUSD, uint256 borrowInUSD) {
        return IValidator(validator).getAccountLiquidity(account);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function enterMarkets(address[] memory lTokens) public override {
        for (uint256 i = 0; i < lTokens.length; i++) {
            _enterMarket(payable(lTokens[i]), msg.sender);
        }
    }

    function exitMarket(address lToken) external override onlyListedMarket(lToken) onlyMemberOfMarket(lToken) {
        Constant.AccountSnapshot memory snapshot = ILToken(lToken).accruedAccountSnapshot(msg.sender);
        require(snapshot.borrowBalance == 0, "Core: borrow balance must be zero");
        require(IValidator(validator).redeemAllowed(lToken, msg.sender, snapshot.lTokenBalance), "Core: cannot redeem");

        _removeUserMarket(lToken, msg.sender);
        emit MarketExited(lToken, msg.sender);
    }

    function supply(
        address lToken,
        uint256 uAmount
    ) external payable override onlyListedMarket(lToken) nonReentrant whenNotPaused returns (uint256) {
        uAmount = ILToken(lToken).underlying() == address(ETH) ? msg.value : uAmount;
        uint256 supplyCap = marketInfos[lToken].supplyCap;
        require(
            supplyCap == 0 ||
                ILToken(lToken).totalSupply().mul(ILToken(lToken).exchangeRate()).div(1e18).add(uAmount) <= supplyCap,
            "Core: supply cap reached"
        );

        uint256 lAmount = ILToken(lToken).supply{value: msg.value}(msg.sender, uAmount);
        labDistributor.notifySupplyUpdated(lToken, msg.sender);

        emit MarketSupply(msg.sender, lToken, uAmount);
        return lAmount;
    }

    function supplyBehalf(
        address supplier,
        address lToken,
        uint256 uAmount
    ) external payable override onlyListedMarket(lToken) nonReentrant whenNotPaused returns (uint256) {
        uAmount = ILToken(lToken).underlying() == address(ETH) ? msg.value : uAmount;
        uint256 supplyCap = marketInfos[lToken].supplyCap;
        require(
            supplyCap == 0 ||
                ILToken(lToken).totalSupply().mul(ILToken(lToken).exchangeRate()).div(1e18).add(uAmount) <= supplyCap,
            "Core: supply cap reached"
        );

        uint256 lAmount = ILToken(lToken).supplyBehalf{value: msg.value}(msg.sender, supplier, uAmount);
        labDistributor.notifySupplyUpdated(lToken, supplier);

        emit MarketSupply(supplier, lToken, uAmount);
        return lAmount;
    }

    function redeemToken(
        address lToken,
        uint256 lAmount
    ) external override onlyListedMarket(lToken) nonReentrant whenNotPaused returns (uint256) {
        uint256 uAmountRedeem = ILToken(lToken).redeemToken(msg.sender, lAmount);
        labDistributor.notifySupplyUpdated(lToken, msg.sender);

        emit MarketRedeem(msg.sender, lToken, uAmountRedeem);
        return uAmountRedeem;
    }

    function redeemUnderlying(
        address lToken,
        uint256 uAmount
    ) external override onlyListedMarket(lToken) nonReentrant whenNotPaused returns (uint256) {
        uint256 uAmountRedeem = ILToken(lToken).redeemUnderlying(msg.sender, uAmount);
        labDistributor.notifySupplyUpdated(lToken, msg.sender);

        emit MarketRedeem(msg.sender, lToken, uAmountRedeem);
        return uAmountRedeem;
    }

    function borrow(
        address lToken,
        uint256 amount
    ) external override onlyListedMarket(lToken) nonReentrant whenNotPaused {
        _enterMarket(lToken, msg.sender);
        require(IValidator(validator).borrowAllowed(lToken, msg.sender, amount), "Core: cannot borrow");

        ILToken(payable(lToken)).borrow(msg.sender, amount);
        labDistributor.notifyBorrowUpdated(lToken, msg.sender);
    }

    function borrowBehalf(
        address borrower,
        address lToken,
        uint256 amount
    ) external override onlyListedMarket(lToken) onlyLeverager nonReentrant whenNotPaused {
        _enterMarket(lToken, borrower);
        require(IValidator(validator).borrowAllowed(lToken, borrower, amount), "Core: cannot borrow");

        ILToken(payable(lToken)).borrowBehalf(msg.sender, borrower, amount);
        labDistributor.notifyBorrowUpdated(lToken, borrower);
    }

    function repayBorrow(
        address lToken,
        uint256 amount
    ) external payable override onlyListedMarket(lToken) nonReentrant whenNotPaused {
        ILToken(payable(lToken)).repayBorrow{value: msg.value}(msg.sender, amount);
        labDistributor.notifyBorrowUpdated(lToken, msg.sender);
    }

    function liquidateBorrow(
        address lTokenBorrowed,
        address lTokenCollateral,
        address borrower,
        uint256 amount
    ) external payable override nonReentrant whenNotPaused {
        amount = ILToken(lTokenBorrowed).underlying() == address(ETH) ? msg.value : amount;
        require(marketInfos[lTokenBorrowed].isListed && marketInfos[lTokenCollateral].isListed, "Core: invalid market");
        require(usersOfMarket[lTokenCollateral][borrower], "Core: not a collateral");
        require(marketInfos[lTokenCollateral].collateralFactor > 0, "Core: not a collateral");
        require(
            IValidator(validator).liquidateAllowed(lTokenBorrowed, borrower, amount, closeFactor),
            "Core: cannot liquidate borrow"
        );

        (, uint256 rebateLAmount, uint256 liquidatorLAmount) = ILToken(lTokenBorrowed).liquidateBorrow{
            value: msg.value
        }(lTokenCollateral, msg.sender, borrower, amount);

        ILToken(lTokenCollateral).seize(msg.sender, borrower, liquidatorLAmount);
        labDistributor.notifyTransferred(lTokenCollateral, borrower, msg.sender);

        if (rebateLAmount > 0) {
            ILToken(lTokenCollateral).seize(rebateDistributor, borrower, rebateLAmount);
            labDistributor.notifyTransferred(lTokenCollateral, borrower, rebateDistributor);
        }

        labDistributor.notifyBorrowUpdated(lTokenBorrowed, borrower);
    }

    function claimLab() external override nonReentrant {
        labDistributor.claim(markets, msg.sender);
    }

    function claimLab(address market) external override nonReentrant {
        address[] memory _markets = new address[](1);
        _markets[0] = market;
        labDistributor.claim(_markets, msg.sender);
    }

    /// @notice 쌓인 보상을 Locker에 바로 deposit
    function compoundLab(uint256 lockDuration) external override nonReentrant {
        labDistributor.compound(markets, msg.sender, lockDuration);
    }

    function transferTokens(
        address spender,
        address src,
        address dst,
        uint256 amount
    ) external override nonReentrant onlyMarket {
        ILToken(msg.sender).transferTokensInternal(spender, src, dst, amount);
        labDistributor.notifyTransferred(msg.sender, src, dst);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _enterMarket(address lToken, address _account) internal onlyListedMarket(lToken) {
        if (!usersOfMarket[lToken][_account]) {
            usersOfMarket[lToken][_account] = true;
            marketListOfUsers[_account].push(lToken);
            emit MarketEntered(lToken, _account);
        }
    }

    function _removeUserMarket(address lTokenToExit, address _account) private {
        require(marketListOfUsers[_account].length > 0, "Core: cannot pop user market");
        delete usersOfMarket[lTokenToExit][_account];

        uint256 length = marketListOfUsers[_account].length;
        for (uint256 i = 0; i < length; i++) {
            if (marketListOfUsers[_account][i] == lTokenToExit) {
                marketListOfUsers[_account][i] = marketListOfUsers[_account][length - 1];
                marketListOfUsers[_account].pop();
                break;
            }
        }
    }
}
