// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;

import "../hub/Spoke.sol";
import "../shares/Shares.sol";
import "./utils/MilestoneFeeBase.sol";

/// @title PerformanceFee Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice Calculates the performance fee for a particular fund
contract PerformanceFee is MilestoneFeeBase {
    event FundSettingsAdded(address indexed feeManager, uint256 rate, uint256 period);

    event FundStateUpdated(address indexed feeManager, uint256 lastPaid, uint256 newHighWaterMark);

    uint256 public constant DIVISOR = 10 ** 18;
    uint256 public constant REDEEM_WINDOW = 1 weeks;

    struct FeeInfo {
        uint256 rate;
        uint256 period;
        uint256 created;
        uint256 lastPaid;
        uint256 highWaterMark;
    }
    mapping (address => FeeInfo) public feeManagerToFeeInfo;

    constructor(address _registry) public MilestoneFeeBase(_registry) {}

    // EXTERNAL FUNCTIONS

    /// @notice Add the initial fee settings for a fund
    /// @param _encodedSettings Encoded settings to apply to a fund
    /// @dev A fund's FeeManager is always the sender
    /// @dev Only called once, on FeeManager.enableFees()
    function addFundSettings(bytes calldata _encodedSettings) external override onlyFeeManager {
        (uint256 feeRate, uint256 feePeriod) = abi.decode(_encodedSettings, (uint256, uint256));
        require(feeRate > 0, "addFundSettings: feeRate must be greater than 0");
        require(feePeriod > 0, "addFundSettings: feePeriod must be greater than 0");

        // TODO: get share price from shares (after Shares.getSharesCostInAsset() refactor)
        feeManagerToFeeInfo[msg.sender] = FeeInfo({
            rate: feeRate,
            period: feePeriod,
            created: block.timestamp,
            lastPaid: block.timestamp,
            highWaterMark: Shares(__getShares()).calcSharePrice()
        });

        emit FundSettingsAdded(msg.sender, feeRate, feePeriod);
    }

    /// @notice Provides a constant string identifier for a fee
    /// @return The identifier string
    function identifier() external pure override returns (string memory) {
        return "PERFORMANCE_MILESTONE";
    }

    /// @notice Settle the fee for an entire fund
    /// @return sharesDue_ The amount of shares that should be created for the manager
    function settleFeeForFund()
        external
        override
        onlyFeeManager
        returns (uint256 sharesDue_)
    {
        // Calculate amount of shares due to manager
        uint256 newHighWaterMark;
        (sharesDue_, newHighWaterMark) = calcSharesDueForFund(msg.sender);
        if (sharesDue_ == 0) return 0;

        // Update fee state for fund
        feeManagerToFeeInfo[msg.sender].lastPaid = block.timestamp;
        feeManagerToFeeInfo[msg.sender].highWaterMark = newHighWaterMark;

        emit FundStateUpdated(msg.sender, block.timestamp, newHighWaterMark);
    }

    /// @notice Settle the fee for an investor
    /// @param _investor The investor for whom to settle the fee
    /// @param _sharesQuantity The quantity of shares for which to settle the fee
    /// @return sharesDue_ The amount of shares that should be reallocated to the manager
    function settleFeeForInvestor(address _investor, uint256 _sharesQuantity)
        external
        override
        onlyFeeManager
        returns (uint256 sharesDue_)
    {
        return calcSharesDueForInvestor(msg.sender, _investor, _sharesQuantity);
    }

    // PUBLIC FUNCTIONS

    /// @notice Calculates the shares due for an entire fund
    /// @param _feeManager The feeManager for which to calculate shares due
    /// @return sharesDue_ The amount of shares that are due
    /// @return newHighWaterMark_ The new high water mark for the fee
    function calcSharesDueForFund(address _feeManager)
        public
        returns (uint256 sharesDue_, uint256 newHighWaterMark_)
    {
        if (!feeIsDue(_feeManager)) return (0, 0);

        uint256 sharesSupply = Shares(__getShares(Spoke(_feeManager).HUB())).totalSupply();
        uint256 rawSharesDue;
        (rawSharesDue, newHighWaterMark_) = __calcRawSharesDue(_feeManager, sharesSupply);
        sharesDue_ = __calcSharesDueWithInflation(rawSharesDue, sharesSupply);
    }

    /// @notice Calculates the shares due for an investor
    /// @param _feeManager The feeManager for which to calculate shares due
    /// @param _sharesQuantity The quantity of shares for which to calculate shares due
    /// @return sharesDue_ The amount of shares that are due
    function calcSharesDueForInvestor(address _feeManager, address, uint256 _sharesQuantity)
        public
        returns (uint256 sharesDue_)
    {
        (sharesDue_,) = __calcRawSharesDue(_feeManager, _sharesQuantity);
    }

    /// @notice Checks whether the fee payment is due
    /// @param _feeManager The feeManager for which to check whether the fee is due
    /// @return True if the fee payment is due
    function feeIsDue(address _feeManager) public view returns (bool) {
        uint256 created = feeManagerToFeeInfo[_feeManager].created;

        // Confirm that within REDEEM_WINDOW for fee
        uint256 timeSinceCreated = sub(block.timestamp, created);
        uint256 timeSinceRedeemWindowStart = timeSinceCreated %
            feeManagerToFeeInfo[_feeManager].period;
        if (timeSinceRedeemWindowStart > REDEEM_WINDOW) return false;

        // Confirm that fees have not been settled in this redemption period
        uint256 redeemWindowStart = sub(block.timestamp, timeSinceRedeemWindowStart);
        return feeManagerToFeeInfo[_feeManager].lastPaid < redeemWindowStart;
    }

    // PRIVATE FUNCTIONS

    /// @dev Helper to calculate the raw shares due (before inflation)
    function __calcRawSharesDue(address _feeManager, uint256 _sharesQuantity)
        private
        returns (uint256 rawSharesDue_, uint256 gavPerShare_)
    {
        Shares shares = Shares(__getShares(Spoke(_feeManager).HUB()));

        // Confirm fund has shares outstanding
        uint256 sharesSupply = shares.totalSupply();
        if (sharesSupply == 0) return (0, 0);

        // Confirm that share price is greater than high water mark
        uint256 oldHighWaterMark = feeManagerToFeeInfo[_feeManager].highWaterMark;
        uint256 gav = shares.calcGav();
        gavPerShare_ = mul(gav, 10 ** uint256(shares.decimals())) / sharesSupply;
        if (gavPerShare_ <= oldHighWaterMark) return (0, gavPerShare_);

        // Calculate shares due
        uint256 sharePriceGain = sub(gavPerShare_, oldHighWaterMark);
        uint256 sharesQuantityGavGain = mul(sharePriceGain, _sharesQuantity) / DIVISOR; // TODO: should divisor here be the denomination asset?
        uint256 feeDueInAsset = mul(
            sharesQuantityGavGain,
            feeManagerToFeeInfo[_feeManager].rate
        ) / DIVISOR;
        rawSharesDue_ = mul(sharesSupply, feeDueInAsset) / gav;
    }
}
