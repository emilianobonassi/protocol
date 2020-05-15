// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;

import "../shares/Shares.sol";
import "./utils/MilestoneFeeBase.sol";

/// @title ManagementFee Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice Calculates the management fee for a particular fund
contract ManagementFee is MilestoneFeeBase {
    event FundSettingsAdded(address indexed feeManager, uint256 rate);

    event FundStateUpdated(address indexed feeManager, uint256 lastPaid);

    struct FeeInfo {
        uint256 rate;
        uint256 lastPaid;
    }
    mapping (address => FeeInfo) public feeManagerToFeeInfo;

    constructor(address _registry) public MilestoneFeeBase(_registry) {}

    // EXTERNAL FUNCTIONS

    /// @notice Add the initial fee settings for a fund
    /// @param _encodedSettings Encoded settings to apply to a fund
    /// @dev A fund's FeeManager is always the sender
    /// @dev Only called once, on FeeManager.enableFees()
    function addFundSettings(bytes calldata _encodedSettings) external override onlyFeeManager {
        uint256 feeRate = abi.decode(_encodedSettings, (uint256));
        require(feeRate > 0, "addFundSettings: feeRate must be greater than 0");

        feeManagerToFeeInfo[msg.sender].rate = feeRate;
        feeManagerToFeeInfo[msg.sender].lastPaid = block.timestamp;

        emit FundSettingsAdded(msg.sender, feeRate);
    }

    /// @notice Provides a constant string identifier for a fee
    /// @return The identifier string
    function identifier() external pure override returns (string memory) {
        return "MANAGEMENT_MILESTONE";
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
        sharesDue_ = calcSharesDueForFund(msg.sender);
        if (sharesDue_ == 0) return 0;

        // Update fee state for fund
        feeManagerToFeeInfo[msg.sender].lastPaid = block.timestamp;

        emit FundStateUpdated(msg.sender, block.timestamp);
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
        // Calculate amount of shares due to manager
        return calcSharesDueForInvestor(msg.sender, _investor, _sharesQuantity);
    }

    // PUBLIC FUNCTIONS

    /// @notice Calculates the shares due for an entire fund
    /// @param _feeManager The feeManager for which to calculate shares due
    /// @return sharesDue_ The amount of shares that are due
    function calcSharesDueForFund(address _feeManager) public view returns (uint256 sharesDue_) {
        uint256 sharesSupply = Shares(__getShares(Spoke(_feeManager).HUB())).totalSupply();
        if (sharesSupply == 0) return 0;

        return __calcSharesDueWithInflation(
            __calcRawSharesDue(_feeManager, sharesSupply),
            sharesSupply
        );
    }

    /// @notice Calculates the shares due for an investor
    /// @param _feeManager The feeManager for which to calculate shares due
    /// @param _sharesQuantity The quantity of shares for which to calculate shares due
    /// @return sharesDue_ The amount of shares that are due
    function calcSharesDueForInvestor(address _feeManager, address, uint256 _sharesQuantity)
        public
        view
        returns (uint256 sharesDue_)
    {
        return __calcRawSharesDue(_feeManager, _sharesQuantity);
    }

    // PRIVATE FUNCTIONS

    /// @dev Helper to calculate the raw shares due (before inflation)
    function __calcRawSharesDue(address _feeManager, uint256 _sharesQuantity)
        private
        view
        returns (uint256)
    {
        uint256 timeSinceLastPaid = sub(
            block.timestamp,
            feeManagerToFeeInfo[_feeManager].lastPaid
        );
        if (timeSinceLastPaid == 0) return 0;

        uint256 yearlySharesDueRate = mul(
            _sharesQuantity,
            feeManagerToFeeInfo[_feeManager].rate
        ) / 10 ** 18;

        // TODO: fine to store as 365 day rate, or should store as per second rate?
        return mul(yearlySharesDueRate, timeSinceLastPaid) / 365 days;
    }
}
