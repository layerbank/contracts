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

    mapping(address => address[]) public marketListOfUsers;
    mapping(address => mapping(address => bool)) public usersOfMarket;

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

    modifier onlyMemberOfMarket(address gToken) {
        require(usersOfMarket[gToken][msg.sender], "Core: must enter market");
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

    /* ========== VIEWS ========== */

    function allMarkets() external view override returns (address[] memory) {
        return markets;
    }

    function marketInfoOf(
        address gToken
    ) external view override returns (Constant.MarketInfo memory) {
        return marketInfos[gToken];
    }

    function marketListOf(
        address account
    ) external view override returns (address[] memory) {
        return marketListOfUsers[account];
    }

    function checkMembership(
        address account,
        address gToken
    ) external view override returns (bool) {
        return usersOfMarket[gToken][account];
    }

    function accountLiquidityOf(
        address account
    )
        external
        view
        override
        returns (
            uint256 collateralInUSD,
            uint256 supplyInUSD,
            uint256 borrowInUSD
        )
    {
        return IValidator(validator).getAccountLiquidity(account);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function enterMarkets(address[] memory gTokens) public override {
        for (uint256 i = 0; i < gTokens.length; i++) {
            _enterMarket(payable(gTokens[i]), msg.sender);
        }
    }

    function exitMarket(
        address gToken
    ) external override onlyListedMarket(gToken) onlyMemberOfMarket(gToken) {
        Constant.AccountSnapshot memory snapshot = ILToken(gToken)
            .accruedAccountSnapshot(msg.sender);
        require(
            snapshot.borrowBalance == 0,
            "Core: borrow balance must be zero"
        );
        require(
            IValidator(validator).redeemAllowed(
                gToken,
                msg.sender,
                snapshot.gTokenBalance
            ),
            "Core: cannot redeem"
        );

        _removeUserMarket(gToken, msg.sender);
        emit MarketExited(gToken, msg.sender);
    }

    function supply(
        address gToken,
        uint256 uAmount
    )
        external
        payable
        override
        onlyListedMarket(gToken)
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        uAmount = ILToken(gToken).underlying() == address(ETH)
            ? msg.value
            : uAmount;
        uint256 supplyCap = marketInfos[gToken].supplyCap;
        require(
            supplyCap == 0 ||
                ILToken(gToken)
                    .totalSupply()
                    .mul(ILToken(gToken).exchangeRate())
                    .div(1e18)
                    .add(uAmount) <=
                supplyCap,
            "Core: supply cap reached"
        );

        uint256 gAmount = ILToken(gToken).supply{value: msg.value}(
            msg.sender,
            uAmount
        );
        labDistributor.notifySupplyUpdated(gToken, msg.sender);

        emit MarketSupply(msg.sender, gToken, uAmount);
        return gAmount;
    }

    function redeemToken(
        address gToken,
        uint256 gAmount
    )
        external
        override
        onlyListedMarket(gToken)
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        uint256 uAmountRedeem = ILToken(gToken).redeemToken(
            msg.sender,
            gAmount
        );
        labDistributor.notifySupplyUpdated(gToken, msg.sender);

        emit MarketRedeem(msg.sender, gToken, uAmountRedeem);
        return uAmountRedeem;
    }

    function redeemUnderlying(
        address gToken,
        uint256 uAmount
    )
        external
        override
        onlyListedMarket(gToken)
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        uint256 uAmountRedeem = ILToken(gToken).redeemUnderlying(
            msg.sender,
            uAmount
        );
        labDistributor.notifySupplyUpdated(gToken, msg.sender);

        emit MarketRedeem(msg.sender, gToken, uAmountRedeem);
        return uAmountRedeem;
    }

    function borrow(
        address gToken,
        uint256 amount
    ) external override onlyListedMarket(gToken) nonReentrant whenNotPaused {
        _enterMarket(gToken, msg.sender);
        require(
            IValidator(validator).borrowAllowed(gToken, msg.sender, amount),
            "Core: cannot borrow"
        );

        ILToken(payable(gToken)).borrow(msg.sender, amount);
        labDistributor.notifyBorrowUpdated(gToken, msg.sender);
    }

    function nftBorrow(
        address gToken,
        address user,
        uint256 amount
    )
        external
        override
        onlyListedMarket(gToken)
        onlyNftCore
        nonReentrant
        whenNotPaused
    {
        require(
            ILToken(gToken).underlying() == address(ETH),
            "Core: invalid underlying asset"
        );
        _enterMarket(gToken, msg.sender);
        ILToken(payable(gToken)).borrow(msg.sender, amount);
        labDistributor.notifyBorrowUpdated(gToken, user);
    }

    function repayBorrow(
        address gToken,
        uint256 amount
    )
        external
        payable
        override
        onlyListedMarket(gToken)
        nonReentrant
        whenNotPaused
    {
        ILToken(payable(gToken)).repayBorrow{value: msg.value}(
            msg.sender,
            amount
        );
        labDistributor.notifyBorrowUpdated(gToken, msg.sender);
    }

    function nftRepayBorrow(
        address gToken,
        address user,
        uint256 amount
    )
        external
        payable
        override
        onlyListedMarket(gToken)
        onlyNftCore
        nonReentrant
        whenNotPaused
    {
        require(
            ILToken(gToken).underlying() == address(ETH),
            "Core: invalid underlying asset"
        );
        ILToken(payable(gToken)).repayBorrow{value: msg.value}(
            msg.sender,
            amount
        );
        labDistributor.notifyBorrowUpdated(gToken, user);
    }

    function repayBorrowBehalf(
        address gToken,
        address borrower,
        uint256 amount
    )
        external
        payable
        override
        onlyListedMarket(gToken)
        nonReentrant
        whenNotPaused
    {
        ILToken(payable(gToken)).repayBorrowBehalf{value: msg.value}(
            msg.sender,
            borrower,
            amount
        );
        labDistributor.notifyBorrowUpdated(gToken, borrower);
    }

    function liquidateBorrow(
        address gTokenBorrowed,
        address gTokenCollateral,
        address borrower,
        uint256 amount
    ) external payable override nonReentrant whenNotPaused {
        amount = ILToken(gTokenBorrowed).underlying() == address(ETH)
            ? msg.value
            : amount;
        require(
            marketInfos[gTokenBorrowed].isListed &&
                marketInfos[gTokenCollateral].isListed,
            "Core: invalid market"
        );
        require(
            usersOfMarket[gTokenCollateral][borrower],
            "Core: not a collateral"
        );
        require(
            marketInfos[gTokenCollateral].collateralFactor > 0,
            "Core: not a collateral"
        );
        require(
            IValidator(validator).liquidateAllowed(
                gTokenBorrowed,
                borrower,
                amount,
                closeFactor
            ),
            "Core: cannot liquidate borrow"
        );

        (, uint256 rebateGAmount, uint256 liquidatorGAmount) = ILToken(
            gTokenBorrowed
        ).liquidateBorrow{value: msg.value}(
            gTokenCollateral,
            msg.sender,
            borrower,
            amount
        );

        ILToken(gTokenCollateral).seize(
            msg.sender,
            borrower,
            liquidatorGAmount
        );
        labDistributor.notifyTransferred(
            gTokenCollateral,
            borrower,
            msg.sender
        );

        if (rebateGAmount > 0) {
            ILToken(gTokenCollateral).seize(
                rebateDistributor,
                borrower,
                rebateGAmount
            );
            labDistributor.notifyTransferred(
                gTokenCollateral,
                borrower,
                rebateDistributor
            );
        }

        labDistributor.notifyBorrowUpdated(gTokenBorrowed, borrower);
    }

    function claimLab() external override nonReentrant {
        labDistributor.claim(markets, msg.sender);
    }

    function claimLab(address market) external override nonReentrant {
        address[] memory _markets = new address[](1);
        _markets[0] = market;
        labDistributor.claim(_markets, msg.sender);
    }

    function compoundLab() external override {
        labDistributor.compound(markets, msg.sender);
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

    function _enterMarket(
        address gToken,
        address _account
    ) internal onlyListedMarket(gToken) {
        if (!usersOfMarket[gToken][_account]) {
            usersOfMarket[gToken][_account] = true;
            marketListOfUsers[_account].push(gToken);
            emit MarketEntered(gToken, _account);
        }
    }

    function _removeUserMarket(address gTokenToExit, address _account) private {
        require(
            marketListOfUsers[_account].length > 0,
            "Core: cannot pop user market"
        );
        delete usersOfMarket[gTokenToExit][_account];

        uint256 length = marketListOfUsers[_account].length;
        for (uint256 i = 0; i < length; i++) {
            if (marketListOfUsers[_account][i] == gTokenToExit) {
                marketListOfUsers[_account][i] = marketListOfUsers[_account][
                    length - 1
                ];
                marketListOfUsers[_account].pop();
                break;
            }
        }
    }
}
