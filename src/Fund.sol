pragma solidity ^0.4.19;

import "./assets/Shares.sol";
import "./assets/ERC223ReceivingContract.sol";
import "./dependencies/DBC.sol";
import "./dependencies/Owned.sol";
import "./assets/NativeAssetInterface.sol";
import "./compliance/ComplianceInterface.sol";
import "./pricefeeds/PriceFeedInterface.sol";
import "./riskmgmt/RiskMgmtInterface.sol";
import "./exchange/ExchangeInterface.sol";
import "./FundInterface.sol";
import "ds-weth/weth9.sol";
import "ds-math/math.sol";

/// @title Melon Fund Contract
/// @author Melonport AG <team@melonport.com>
/// @notice Simple Melon Fund
contract Fund is DSMath, DBC, Owned, Shares, FundInterface, ERC223ReceivingContract {
    // TYPES

    struct Modules { // Describes all modular parts, standardised through an interface
        PriceFeedInterface pricefeed; // Provides all external data
        address[] exchanges; // Array containing multiple exchange addresses
        ExchangeInterface[] exchangeAdapters; // Array containing exchange adapter contracts respective to the exchanges
        ComplianceInterface compliance; // Boolean functions regarding invest/redeem
        RiskMgmtInterface riskmgmt; // Boolean functions regarding make/take orders
    }

    struct Calculations { // List of internal calculations
        uint gav; // Gross asset value
        uint managementReward; // Time based reward
        uint performanceReward; // Performance based reward measured against BASE_ASSET
        uint unclaimedRewards; // Rewards not yet allocated to the fund manager
        uint nav; // Net asset value
        uint highWaterMark; // A record of best all-time fund performance
        uint totalSupply; // Total supply of shares
        uint timestamp; // Time when calculations are performed in seconds
    }

    enum RequestStatus { active, cancelled, executed }
    enum RequestType { subscribe, redeem, tokenFallbackRedeem }
    struct Request { // Describes and logs whenever asset enter and leave fund due to Participants
        address participant; // Participant in Melon fund requesting subscription or redemption
        RequestStatus status; // Enum: active, cancelled, executed; Status of request
        RequestType requestType; // Enum: subscribe, redeem
        address requestAsset; // Address of the asset being requested
        uint shareQuantity; // Quantity of Melon fund shares
        uint giveQuantity; // Quantity in Melon asset to give to Melon fund to receive shareQuantity
        uint receiveQuantity; // Quantity in Melon asset to receive from Melon fund for given shareQuantity
        uint timestamp;     // Time of request creation in seconds
        uint atUpdateId;    // Pricefeed updateId when this request was created
    }

    enum OrderStatus { active, partiallyFilled, fullyFilled, cancelled }
    enum OrderType { make, take }
    struct Order { // Describes and logs whenever assets enter and leave fund due to Manager
        uint exchangeId; // Id as returned from exchange
        OrderStatus status; // Enum: active, partiallyFilled, fullyFilled, cancelled
        OrderType orderType; // Enum: make, take
        address sellAsset; // Asset (as registered in Asset registrar) to be sold
        address buyAsset; // Asset (as registered in Asset registrar) to be bought
        uint sellQuantity; // Quantity of sellAsset to be sold
        uint buyQuantity; // Quantity of sellAsset to be bought
        uint timestamp; // Time of order creation in seconds
        uint fillQuantity; // Buy quantity filled; Always less than buy_quantity
    }

    // FIELDS

    // Constant fields
    uint public constant MAX_FUND_ASSETS = 90; // Max ownable assets by the fund supported by gas limits
    // Constructor fields
    uint public MANAGEMENT_REWARD_RATE; // Reward rate in BASE_ASSET per delta improvement
    uint public PERFORMANCE_REWARD_RATE; // Reward rate in BASE_ASSET per managed seconds
    address public VERSION; // Address of Version contract
    Asset public BASE_ASSET; // Base asset as ERC20 contract
    NativeAssetInterface public NATIVE_ASSET; // Native asset as ERC20 contract
    // Methods fields
    Modules public module; // Struct which holds all the initialised module instances
    Calculations public atLastUnclaimedRewardAllocation; // Calculation results at last allocateUnclaimedRewards() call
    bool public isShutDown; // Security feature, if yes than investing, managing, allocateUnclaimedRewards gets blocked
    Request[] public requests; // All the requests this fund received from participants
    bool public isSubscribeAllowed; // User option, if false fund rejects Melon investments
    bool public isRedeemAllowed; // User option, if false fund rejects Melon redemptions; Redemptions using slices always possible
    Order[] public orders; // All the orders this fund placed on exchanges
    mapping (uint => mapping(address => uint)) public exchangeIdsToOpenMakeOrderIds; // exchangeIndex to: asset to open make order ID ; if no open make orders, orderID is zero
    address[] public ownedAssets; // List of all assets owned by the fund or for which the fund has open make orders
    address[] public tempOwnedAssets; // Intended as a local variable for calcGav method, but declaring as global to overcome Solidity limtation
    mapping (address => bool) public isInAssetList; // Mapping from asset to whether the asset exists in ownedAssets
    mapping (address => bool) public isInOpenMakeOrder; // Mapping from asset to whether the asset is in a open make order as buy asset

    // METHODS

    // CONSTRUCTOR

    /// @dev Should only be called via Version.setupFund(..)
    /// @param withName human-readable descriptive name (not necessarily unique)
    /// @param ofBaseAsset Asset against which mgmt and performance reward is measured against and which can be used to invest/redeem using this single asset
    /// @param ofManagementRewardRate A time based reward expressed, given in a number which is divided by 1 WAD
    /// @param ofPerformanceRewardRate A time performance based reward, performance relative to ofBaseAsset, given in a number which is divided by 1 WAD
    /// @param ofCompliance Address of compliance module
    /// @param ofRiskMgmt Address of risk management module
    /// @param ofPriceFeed Address of price feed module
    /// @param ofExchanges Addresses of exchange on which this fund can trade
    /// @param ofExchangeAdapters Addresses of exchange adapters
    /// @return Deployed Fund with manager set as ofManager
    function Fund(
        address ofManager,
        string withName,
        address ofBaseAsset,
        uint ofManagementRewardRate,
        uint ofPerformanceRewardRate,
        address ofNativeAsset,
        address ofCompliance,
        address ofRiskMgmt,
        address ofPriceFeed,
        address[] ofExchanges,
        address[] ofExchangeAdapters
    )
        Shares(withName, "MLNF", 18, now)
    {
        isSubscribeAllowed = true;
        isRedeemAllowed = true;
        owner = ofManager;
        require(ofManagementRewardRate < 10 ** 18); // Require management reward to be less than 100 percent
        MANAGEMENT_REWARD_RATE = ofManagementRewardRate; // 1 percent is expressed as 0.01 * 10 ** 18
        require(ofPerformanceRewardRate < 10 ** 18); // Require performance reward to be less than 100 percent
        PERFORMANCE_REWARD_RATE = ofPerformanceRewardRate; // 1 percent is expressed as 0.01 * 10 ** 18
        VERSION = msg.sender;
        module.compliance = ComplianceInterface(ofCompliance);
        module.riskmgmt = RiskMgmtInterface(ofRiskMgmt);
        module.pricefeed = PriceFeedInterface(ofPriceFeed);
        // Bridged to Melon exchange interface by exchangeAdapter library
        for (uint i = 0; i < ofExchanges.length; ++i) {
            module.exchanges.push(ofExchanges[i]);
            module.exchangeAdapters.push(ExchangeInterface(ofExchangeAdapters[i]));
        }
        // Require base assets exists in pricefeed
        BASE_ASSET = Asset(ofBaseAsset);
        NATIVE_ASSET = NativeAssetInterface(ofNativeAsset);
        require(address(BASE_ASSET) == module.pricefeed.getQuoteAsset()); // Sanity check
        atLastUnclaimedRewardAllocation = Calculations({
            gav: 0,
            managementReward: 0,
            performanceReward: 0,
            unclaimedRewards: 0,
            nav: 0,
            highWaterMark: 10 ** getDecimals(),
            totalSupply: totalSupply,
            timestamp: now
        });
    }

    // EXTERNAL METHODS

    // EXTERNAL : ADMINISTRATION

    function enableSubscription() external pre_cond(isOwner()) { isSubscribeAllowed = true; }
    function disableSubscription() external pre_cond(isOwner()) { isSubscribeAllowed = false; }
    function enableRedemption() external pre_cond(isOwner()) { isRedeemAllowed = true; }
    function disableRedemption() external pre_cond(isOwner()) { isRedeemAllowed = false; }
    function shutDown() external pre_cond(msg.sender == VERSION) { isShutDown = true; }


    // EXTERNAL : PARTICIPATION

    /// @notice Give melon tokens to receive shares of this fund
    /// @dev Recommended to give some leeway in prices to account for possibly slightly changing prices
    /// @param giveQuantity Quantity of Melon token times 10 ** 18 offered to receive shareQuantity
    /// @param shareQuantity Quantity of shares times 10 ** 18 requested to be received
    function requestSubscription(
        uint giveQuantity,
        uint shareQuantity,
        bool isNativeAsset
    )
        external
        pre_cond(!isShutDown)
        pre_cond(isSubscribeAllowed)    // subscription using Melon has not been deactivated by the Manager
        pre_cond(module.compliance.isSubscriptionPermitted(msg.sender, giveQuantity, shareQuantity))    // Compliance Module: Subscription permitted
    {
        requests.push(Request({
            participant: msg.sender,
            status: RequestStatus.active,
            requestType: RequestType.subscribe,
            requestAsset: isNativeAsset ? address(NATIVE_ASSET) : address(BASE_ASSET),
            shareQuantity: shareQuantity,
            giveQuantity: giveQuantity,
            receiveQuantity: shareQuantity,
            timestamp: now,
            atUpdateId: module.pricefeed.getLastUpdateId()
        }));
        RequestUpdated(getLastRequestId());
    }

    /// @notice Give shares of this fund to receive melon tokens
    /// @dev Recommended to give some leeway in prices to account for possibly slightly changing prices
    /// @param shareQuantity Quantity of shares times 10 ** 18 offered to redeem
    /// @param receiveQuantity Quantity of Melon token times 10 ** 18 requested to receive for shareQuantity
    function requestRedemption(
        uint shareQuantity,
        uint receiveQuantity,
        bool isNativeAsset
      )
        external
        pre_cond(!isShutDown)
        pre_cond(isRedeemAllowed) // Redemption using Melon has not been deactivated by Manager
        pre_cond(module.compliance.isRedemptionPermitted(msg.sender, shareQuantity, receiveQuantity)) // Compliance Module: Redemption permitted
    {
        requests.push(Request({
            participant: msg.sender,
            status: RequestStatus.active,
            requestType: RequestType.redeem,
            requestAsset: isNativeAsset ? address(NATIVE_ASSET) : address(BASE_ASSET),
            shareQuantity: shareQuantity,
            giveQuantity: shareQuantity,
            receiveQuantity: receiveQuantity,
            timestamp: now,
            atUpdateId: module.pricefeed.getLastUpdateId()
        }));
        RequestUpdated(getLastRequestId());
    }

    /// @notice Executes active subscription and redemption requests, in a way that minimises information advantages of investor
    /// @dev Distributes melon and shares according to the request
    /// @param id Index of request to be executed
    /// @dev Active subscription or redemption request executed
    function executeRequest(uint id)
        external
        pre_cond(!isShutDown)
        pre_cond(requests[id].status == RequestStatus.active)
        pre_cond(requests[id].requestType != RequestType.redeem || requests[id].shareQuantity <= balances[requests[id].participant]) // request owner does not own enough shares
        pre_cond(
            totalSupply == 0 ||
            (
                now >= add(requests[id].timestamp, module.pricefeed.getInterval()) &&
                module.pricefeed.getLastUpdateId() >= add(requests[id].atUpdateId, 2)
            )
        )   // PriceFeed Module: Wait at least one interval time and two updates before continuing (unless it is the first subscription)
         // PriceFeed Module: No recent updates for fund asset list
    {
        // sharePrice quoted in BASE_ASSET and multiplied by 10 ** fundDecimals
        // based in BASE_ASSET and multiplied by 10 ** fundDecimals
        require(module.pricefeed.hasRecentPrice(address(BASE_ASSET)));
        require(module.pricefeed.hasRecentPrices(ownedAssets));
        var (isRecent, , ) = module.pricefeed.getInvertedPrice(address(BASE_ASSET));
        // TODO: check precision of below otherwise use; uint costQuantity = toWholeShareUnit(mul(request.shareQuantity, calcSharePrice()));
        // By definition quoteDecimals == fundDecimals
        Request request = requests[id];

        uint costQuantity = toWholeShareUnit(mul(request.shareQuantity, calcSharePrice()));
        if (request.requestAsset == address(NATIVE_ASSET)) {
            var (isPriceRecent, invertedNativeAssetPrice, nativeAssetDecimal) = module.pricefeed.getInvertedPrice(address(NATIVE_ASSET));
            if (!isPriceRecent) {
                revert();
            }
            costQuantity = mul(costQuantity, invertedNativeAssetPrice) / 10 ** nativeAssetDecimal;
        }

        if (
            isSubscribeAllowed &&
            request.requestType == RequestType.subscribe &&
            costQuantity <= request.giveQuantity
        ) {
            if (!isInAssetList[address(BASE_ASSET)]) {
                ownedAssets.push(address(BASE_ASSET));
                isInAssetList[address(BASE_ASSET)] = true;
            }
            request.status = RequestStatus.executed;
            assert(AssetInterface(request.requestAsset).transferFrom(request.participant, this, costQuantity)); // Allocate Value
            createShares(request.participant, request.shareQuantity); // Accounting
        } else if (
            isRedeemAllowed &&
            request.requestType == RequestType.redeem &&
            request.receiveQuantity <= costQuantity
        ) {
            request.status = RequestStatus.executed;
            assert(AssetInterface(request.requestAsset).transfer(request.participant, costQuantity)); // Return value
            annihilateShares(request.participant, request.shareQuantity); // Accounting
        } else if (
            isRedeemAllowed &&
            request.requestType == RequestType.tokenFallbackRedeem &&
            request.receiveQuantity <= costQuantity
        ) {
            request.status = RequestStatus.executed;
            assert(AssetInterface(request.requestAsset).transfer(request.participant, costQuantity)); // Return value
            annihilateShares(this, request.shareQuantity); // Accounting
        } else {
            revert(); // Invalid Request or invalid giveQuantity / receiveQuantity
        }
    }

    /// @notice Cancels active subscription and redemption requests
    /// @param id Index of request to be executed
    function cancelRequest(uint id)
        external
        pre_cond(requests[id].status == RequestStatus.active) // Request is active
        pre_cond(requests[id].participant == msg.sender || isShutDown) // Either request creator or fund is shut down
    {
        requests[id].status = RequestStatus.cancelled;
    }

    /// @notice Redeems by allocating an ownership percentage of each asset to the participant
    /// @dev Independent of running price feed!
    /// @param shareQuantity Number of shares owned by the participant, which the participant would like to redeem for individual assets
    /// @return Whether all assets sent to shareholder or not
    function redeemAllOwnedAssets(uint shareQuantity)
        external
        returns (bool success)
    {
        return emergencyRedeem(shareQuantity, ownedAssets);
    }

    // EXTERNAL : MANAGING

    /// @notice Makes an order on the selected exchange
    /// @dev These are orders that are not expected to settle immediately.  Sufficient balance (== sellQuantity) of sellAsset
    /// @param sellAsset Asset (as registered in Asset registrar) to be sold
    /// @param buyAsset Asset (as registered in Asset registrar) to be bought
    /// @param sellQuantity Quantity of sellAsset to be sold
    /// @param buyQuantity Quantity of buyAsset to be bought
    function makeOrder(
        uint exchangeNumber,
        address sellAsset,
        address buyAsset,
        uint sellQuantity,
        uint buyQuantity
    )
        external
        pre_cond(isOwner())
        pre_cond(!isShutDown)
    {
        require(buyAsset != address(this)); // Prevent buying of own fund token
        require(quantityHeldInCustodyOfExchange(sellAsset) == 0); // Curr only one make order per sellAsset allowed. Please wait or cancel existing make order.
        require(module.pricefeed.existsPriceOnAssetPair(sellAsset, buyAsset)); // PriceFeed module: Requested asset pair not valid
        var (isRecent, referencePrice, ) = module.pricefeed.getReferencePrice(sellAsset, buyAsset);
        require(isRecent);  // Reference price is required to be recent
        require(
            module.riskmgmt.isMakePermitted(
                module.pricefeed.getOrderPrice(
                    sellAsset,
                    buyAsset,
                    sellQuantity,
                    buyQuantity
                ),
                referencePrice,
                sellAsset,
                buyAsset,
                sellQuantity,
                buyQuantity
            )
        ); // RiskMgmt module: Make order not permitted
        require(isInAssetList[buyAsset] || ownedAssets.length < MAX_FUND_ASSETS); // Limit for max ownable assets by the fund reached
        require(AssetInterface(sellAsset).approve(module.exchanges[exchangeNumber], sellQuantity)); // Approve exchange to spend assets

        // Since there is only one openMakeOrder allowed for each asset, we can assume that openMakeOrderId is set as zero by quantityHeldInCustodyOfExchange() function
        require(address(module.exchangeAdapters[exchangeNumber]).delegatecall(bytes4(keccak256("makeOrder(address,address,address,uint256,uint256)")), module.exchanges[exchangeNumber], sellAsset, buyAsset, sellQuantity, buyQuantity));
        exchangeIdsToOpenMakeOrderIds[exchangeNumber][sellAsset] = module.exchangeAdapters[exchangeNumber].getLastOrderId(module.exchanges[exchangeNumber]);

        // Success defined as non-zero order id
        require(exchangeIdsToOpenMakeOrderIds[exchangeNumber][sellAsset] != 0);

        // Update ownedAssets array and isInAssetList, isInOpenMakeOrder mapping
        isInOpenMakeOrder[sellAsset] = true;
        if (!isInAssetList[buyAsset]) {
            ownedAssets.push(buyAsset);
            isInAssetList[buyAsset] = true;
        }

        orders.push(Order({
            exchangeId: exchangeIdsToOpenMakeOrderIds[exchangeNumber][sellAsset],
            status: OrderStatus.active,
            orderType: OrderType.make,
            sellAsset: sellAsset,
            buyAsset: buyAsset,
            sellQuantity: sellQuantity,
            buyQuantity: buyQuantity,
            timestamp: now,
            fillQuantity: 0
        }));

        OrderUpdated(exchangeIdsToOpenMakeOrderIds[exchangeNumber][sellAsset]);
    }

    /// @notice Takes an active order on the selected exchange
    /// @dev These are orders that are expected to settle immediately
    /// @param id Active order id
    /// @param receiveQuantity Buy quantity of what others are selling on selected Exchange
    function takeOrder(uint exchangeNumber, uint id, uint receiveQuantity)
        external
        pre_cond(isOwner())
        pre_cond(!isShutDown)
    {
        // Get information of order by order id
        Order memory order; // Inverse variable terminology! Buying what another person is selling
        (
            order.sellAsset,
            order.buyAsset,
            order.sellQuantity,
            order.buyQuantity
        ) = module.exchangeAdapters[exchangeNumber].getOrder(module.exchanges[exchangeNumber], id);
        // Check pre conditions
        require(order.sellAsset != address(this)); // Prevent buying of own fund token
        require(module.pricefeed.existsPriceOnAssetPair(order.buyAsset, order.sellAsset)); // PriceFeed module: Requested asset pair not valid
        require(isInAssetList[order.sellAsset] || ownedAssets.length < MAX_FUND_ASSETS); // Limit for max ownable assets by the fund reached
        var (isRecent, referencePrice, ) = module.pricefeed.getReferencePrice(order.buyAsset, order.sellAsset);
        require(isRecent); // Reference price is required to be recent
        require(receiveQuantity <= order.sellQuantity); // Not enough quantity of order for what is trying to be bought
        uint spendQuantity = mul(receiveQuantity, order.buyQuantity) / order.sellQuantity;
        require(AssetInterface(order.buyAsset).approve(module.exchanges[exchangeNumber], spendQuantity)); // Could not approve spending of spendQuantity of order.buyAsset
        require(
            module.riskmgmt.isTakePermitted(
            module.pricefeed.getOrderPrice(
                order.buyAsset,
                order.sellAsset,
                order.buyQuantity, // spendQuantity
                order.sellQuantity // receiveQuantity
            ),
            referencePrice,
            order.buyAsset,
            order.sellAsset,
            order.buyQuantity,
            order.sellQuantity
        )); // RiskMgmt module: Take order not permitted

        // Execute request
        require(address(module.exchangeAdapters[exchangeNumber]).delegatecall(bytes4(keccak256("takeOrder(address,uint256,uint256)")), module.exchanges[exchangeNumber], id, receiveQuantity));

        // Update ownedAssets array and isInAssetList mapping
        if (!isInAssetList[order.sellAsset]) {
            ownedAssets.push(order.sellAsset);
            isInAssetList[order.sellAsset] = true;
        }

        order.exchangeId = id;
        order.status = OrderStatus.fullyFilled;
        order.orderType = OrderType.take;
        order.timestamp = now;
        order.fillQuantity = receiveQuantity;
        orders.push(order);
        OrderUpdated(id);
    }

    /// @notice Cancels orders that were not expected to settle immediately, i.e. makeOrders
    /// @dev Reduce exposure with exchange interaction
    /// @param id Active order id of this order array with order owner of this contract on selected Exchange
    function cancelOrder(uint exchangeNumber, uint id)
        external
        pre_cond(isOwner() || isShutDown)
    {
        // Get information of fund order by order id
        Order order = orders[id];

        // Execute request
        require(address(module.exchangeAdapters[exchangeNumber]).delegatecall(bytes4(keccak256("cancelOrder(address,uint256)")), module.exchanges[exchangeNumber], order.exchangeId));

        order.status = OrderStatus.cancelled;
        OrderUpdated(id);
    }


    // PUBLIC METHODS

    // PUBLIC METHODS : ERC223

    /// @dev Standard ERC223 function that handles incoming token transfers.
    /// @dev This type of redemption can be seen as a "market order", where price is calculated at execution time
    /// @param ofSender  Token sender address.
    /// @param tokenAmount Amount of tokens sent.
    /// @param metadata  Transaction metadata.
    function tokenFallback(
        address ofSender,
        uint tokenAmount,
        bytes metadata
    ) {
        if (msg.sender != address(this)) {
            return; // when ERC223 asset is not Shares, just receive it and do nothing
        } else {    // otherwise, make a redemption request
            requests.push(Request({
                participant: ofSender,
                status: RequestStatus.active,
                requestType: RequestType.tokenFallbackRedeem,
                requestAsset: address(BASE_ASSET), // redeem in BASE_ASSET
                shareQuantity: tokenAmount,
                giveQuantity: tokenAmount,              // shares being sent
                receiveQuantity: 0,          // value of the shares at request time
                timestamp: now,
                atUpdateId: module.pricefeed.getLastUpdateId()
            }));
            RequestUpdated(getLastRequestId());
        }
    }


    // PUBLIC METHODS : ACCOUNTING

    /// @notice Calculates gross asset value of the fund
    /// @dev Decimals in assets must be equal to decimals in PriceFeed for all entries in AssetRegistrar
    /// @dev Assumes that module.pricefeed.getPrice(..) returns recent prices
    /// @return gav Gross asset value quoted in BASE_ASSET and multiplied by 10 ** shareDecimals
    function calcGav() returns (uint gav) {
        // prices quoted in BASE_ASSET and multiplied by 10 ** assetDecimal
        tempOwnedAssets = ownedAssets;
        delete ownedAssets;
        for (uint i = 0; i < tempOwnedAssets.length; ++i) {
            address ofAsset = tempOwnedAssets[i];
            // assetHoldings formatting: mul(exchangeHoldings, 10 ** assetDecimal)
            uint assetHoldings = add(
                uint(AssetInterface(ofAsset).balanceOf(this)), // asset base units held by fund
                quantityHeldInCustodyOfExchange(ofAsset)
            );
            // assetPrice formatting: mul(exchangePrice, 10 ** assetDecimal)
            var (isRecent, assetPrice, assetDecimals) = module.pricefeed.getPrice(ofAsset);
            if (!isRecent) {
                revert();
            }
            // gav as sum of mul(assetHoldings, assetPrice) with formatting: mul(mul(exchangeHoldings, exchangePrice), 10 ** shareDecimals)
            gav = add(gav, mul(assetHoldings, assetPrice) / (10 ** uint256(assetDecimals)));   // Sum up product of asset holdings of this vault and asset prices
            if (assetHoldings != 0 || ofAsset == address(BASE_ASSET) || isInOpenMakeOrder[ofAsset]) { // Check if asset holdings is not zero or is address(BASE_ASSET) or in open make order
                ownedAssets.push(ofAsset);
            } else {
                isInAssetList[ofAsset] = false; // Remove from ownedAssets if asset holdings are zero
            }
            PortfolioContent(assetHoldings, assetPrice, assetDecimals);
        }
    }

    /**
    @notice Calculates unclaimed rewards of the fund manager
    @param gav Gross asset value in BASE_ASSET and multiplied by 10 ** shareDecimals
    @return {
      "managementReward": "A time (seconds) based reward in BASE_ASSET and multiplied by 10 ** shareDecimals",
      "performanceReward": "A performance (rise of sharePrice measured in BASE_ASSET) based reward in BASE_ASSET and multiplied by 10 ** shareDecimals",
      "unclaimedRewards": "The sum of both managementReward and performanceReward in BASE_ASSET and multiplied by 10 ** shareDecimals"
    }
    */
    function calcUnclaimedRewards(uint gav)
        view
        returns (
            uint managementReward,
            uint performanceReward,
            uint unclaimedRewards)
    {
        // Management reward calculation
        uint timePassed = sub(now, atLastUnclaimedRewardAllocation.timestamp);
        uint gavPercentage = mul(timePassed, gav) / (1 years);
        managementReward = wmul(gavPercentage, MANAGEMENT_REWARD_RATE);

        // Performance reward calculation
        // Handle potential division through zero by defining a default value
        uint valuePerShareExclPerfRewards = totalSupply > 0 ? calcValuePerShare(sub(gav, managementReward), totalSupply) : toSmallestShareUnit(1);
        if (valuePerShareExclPerfRewards > atLastUnclaimedRewardAllocation.highWaterMark) {
            uint gainInSharePrice = sub(valuePerShareExclPerfRewards, atLastUnclaimedRewardAllocation.highWaterMark);
            uint investmentProfits = wmul(gainInSharePrice, totalSupply);
            performanceReward = wmul(investmentProfits, PERFORMANCE_REWARD_RATE);
        }

        // Sum of all rewards
        unclaimedRewards = add(managementReward, performanceReward);
    }

    /// @notice Calculates the Net asset value of this fund
    /// @param gav Gross asset value of this fund in BASE_ASSET and multiplied by 10 ** shareDecimals
    /// @param unclaimedRewards The sum of both managementReward and performanceReward in BASE_ASSET and multiplied by 10 ** shareDecimals
    /// @return nav Net asset value in BASE_ASSET and multiplied by 10 ** shareDecimals
    function calcNav(uint gav, uint unclaimedRewards)
        view
        returns (uint nav)
    {
        nav = sub(gav, unclaimedRewards);
    }

    /// @notice Calculates the share price of the fund
    /// @dev Convention for valuePerShare (== sharePrice) formatting: mul(totalValue / numShares, 10 ** decimal), to avoid floating numbers
    /// @dev Non-zero share supply; value denominated in [base unit of melonAsset]
    /// @param totalValue the total value in BASE_ASSET and multiplied by 10 ** shareDecimals
    /// @param numShares the number of shares multiplied by 10 ** shareDecimals
    /// @return valuePerShare Share price denominated in BASE_ASSET and multiplied by 10 ** shareDecimals
    function calcValuePerShare(uint totalValue, uint numShares)
        view
        pre_cond(numShares > 0)
        returns (uint valuePerShare)
    {
        valuePerShare = toSmallestShareUnit(totalValue) / numShares;
    }

    /**
    @notice Calculates essential fund metrics
    @return {
      "gav": "Gross asset value of this fund denominated in [base unit of melonAsset]",
      "managementReward": "A time (seconds) based reward",
      "performanceReward": "A performance (rise of sharePrice measured in BASE_ASSET) based reward",
      "unclaimedRewards": "The sum of both managementReward and performanceReward denominated in [base unit of melonAsset]",
      "rewardsShareQuantity": "The number of shares to be given as rewards to the manager",
      "nav": "Net asset value denominated in [base unit of melonAsset]",
      "sharePrice": "Share price denominated in [base unit of melonAsset]"
    }
    */
    function performCalculations()
        view
        returns (
            uint gav,
            uint managementReward,
            uint performanceReward,
            uint unclaimedRewards,
            uint rewardsShareQuantity,
            uint nav,
            uint sharePrice
        )
    {
        gav = calcGav(); // Reflects value independent of fees
        (managementReward, performanceReward, unclaimedRewards) = calcUnclaimedRewards(gav);
        nav = calcNav(gav, unclaimedRewards);

        // The value of unclaimedRewards measured in shares of this fund at current value
        rewardsShareQuantity = (gav == 0) ? 0 : mul(totalSupply, unclaimedRewards) / gav;
        // The total share supply including the value of unclaimedRewards, measured in shares of this fund
        uint totalSupplyAccountingForRewards = add(totalSupply, rewardsShareQuantity);
        sharePrice = nav > 0 ? calcValuePerShare(nav, totalSupplyAccountingForRewards) : toSmallestShareUnit(1); // Handle potential division through zero by defining a default value
    }

    /// @notice Converts unclaimed fees of the manager into fund shares
    /// @dev Only Owner
    function allocateUnclaimedRewards()
        pre_cond(isOwner())
    {
        var (
            gav,
            managementReward,
            performanceReward,
            unclaimedRewards,
            rewardsShareQuantity,
            nav,
            sharePrice
        ) = performCalculations();

        createShares(owner, rewardsShareQuantity); // Updates totalSupply by creating shares allocated to manager

        // Update Calculations
        uint updatedHighWaterMark = atLastUnclaimedRewardAllocation.highWaterMark >= sharePrice ? atLastUnclaimedRewardAllocation.highWaterMark : sharePrice;
        atLastUnclaimedRewardAllocation = Calculations({
            gav: gav,
            managementReward: managementReward,
            performanceReward: performanceReward,
            unclaimedRewards: unclaimedRewards,
            nav: nav,
            highWaterMark: updatedHighWaterMark,
            totalSupply: totalSupply,
            timestamp: now
        });

        RewardsConverted(now, rewardsShareQuantity, unclaimedRewards);
        CalculationUpdate(now, managementReward, performanceReward, nav, sharePrice, totalSupply);
    }

    /// @notice allows manager to recover tokens sent to the Fund
    /// @param ofAsset Address of the token
    /// @param toAddress Address to send the tokens to
    /// @param amount Amount of the token to send
    function recoverToken(address ofAsset, address toAddress, uint amount)
        pre_cond(isOwner())
    {
        require(AssetInterface(ofAsset).transfer(toAddress, amount));
    }

    // PUBLIC : REDEEMING

    /// @notice Redeems by allocating an ownership percentage only of requestedAssets to the participant
    /// @dev Independent of running price feed! Note: if requestedAssets != ownedAssets then participant misses out on some owned value
    /// @param shareQuantity Number of shares owned by the participant, which the participant would like to redeem for individual assets
    /// @param requestedAssets List of addresses that consitute a subset of ownedAssets.
    /// @return Whether all assets sent to shareholder or not
    function emergencyRedeem(uint shareQuantity, address[] requestedAssets)
        public
        pre_cond(balances[msg.sender] >= shareQuantity)  // sender owns enough shares
        returns (bool)
    {
        uint[] memory ownershipQuantities = new uint[](requestedAssets.length);

        // Check whether enough assets held by fund
        for (uint i = 0; i < requestedAssets.length; ++i) {
            address ofAsset = requestedAssets[i];
            uint assetHoldings = add(
                uint(AssetInterface(ofAsset).balanceOf(this)),
                quantityHeldInCustodyOfExchange(ofAsset)
            );

            if (assetHoldings == 0) continue;

            // participant's ownership percentage of asset holdings
            ownershipQuantities[i] = mul(assetHoldings, shareQuantity) / totalSupply;

            // CRITICAL ERR: Not enough assetHoldings for owed ownershipQuantitiy, eg in case of unreturned asset quantity at address(module.exchange) address
            if (assetHoldings < ownershipQuantities[i]) {
                isShutDown = true;
                ErrorMessage("CRITICAL ERR: Not enough assetHoldings for owed ownershipQuantitiy");
                return false;
            }
        }

        // Annihilate shares before external calls to prevent reentrancy
        annihilateShares(msg.sender, shareQuantity);

        // Transfer ownershipQuantity of Assets
        for (uint j = 0; j < ownershipQuantities.length; ++j) {
            // Failed to send owed ownershipQuantity from fund to participant
            if (!AssetInterface(ofAsset).transfer(msg.sender, ownershipQuantities[j])) {
                revert();
            }
        }
        Redeemed(msg.sender, now, shareQuantity);
        return true;
    }

    // PUBLIC : REWARDS

    /// @dev Quantity of asset held in exchange according to associated order id
    /// @param ofAsset Address of asset
    /// @return Quantity of input asset held in exchange
    function quantityHeldInCustodyOfExchange(address ofAsset) returns (uint) {
        uint totalSellQuantity;     // quantity in custody across exchanges
        for (uint i; i < module.exchanges.length; i++) {
            if (exchangeIdsToOpenMakeOrderIds[i][ofAsset] == 0) {
                continue;
            }
            var (sellAsset, , sellQuantity, ) = module.exchangeAdapters[i].getOrder(module.exchanges[i], exchangeIdsToOpenMakeOrderIds[i][ofAsset]);
            if (sellQuantity == 0) {
                exchangeIdsToOpenMakeOrderIds[i][ofAsset] = 0;
            }
            totalSellQuantity += sellQuantity;
        }
        if (totalSellQuantity == 0) {
            isInOpenMakeOrder[sellAsset] = false;
        }
        return totalSellQuantity;
    }

    // PUBLIC VIEW METHODS

    /// @notice Calculates sharePrice denominated in [base unit of melonAsset]
    /// @return sharePrice Share price denominated in [base unit of melonAsset]
    function calcSharePrice() view returns (uint sharePrice) {
        (, , , , , sharePrice) = performCalculations();
        return sharePrice;
    }

    function getModules() view returns (address, address[], address, address) {
        return (
            address(module.pricefeed),
            module.exchanges,
            address(module.compliance),
            address(module.riskmgmt)
        );
    }

    function getLastOrderId() view returns (uint) { return orders.length - 1; }
    function getLastRequestId() view returns (uint) { return requests.length - 1; }
    function getNameHash() view returns (bytes32) { return bytes32(keccak256(name)); }
    function getManager() view returns (address) { return owner; }
}
