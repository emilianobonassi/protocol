// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;
pragma experimental ABIEncoderV2;

import "../../dependencies/DSMath.sol";
import "../../dependencies/libs/EnumerableSet.sol";
import "../hub/Spoke.sol";
import "./IFee.sol";
import "./IFeeManager.sol";

/// @title FeeManager Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice Manages and allocates fees for a particular fund
contract FeeManager is IFeeManager, DSMath, Spoke {
    using EnumerableSet for EnumerableSet.AddressSet;

    event FeeEnabled(address indexed fee, bytes encodedSettings);

    event FeeSettledForFund(address indexed fee, uint256 sharesDue);

    event FeeSettledForInvestor(
        address indexed fee,
        address indexed investor,
        uint256 sharesQuantity,
        uint256 sharesDue
    );

    EnumerableSet.AddressSet private enabledFees;

    constructor(address _hub) Spoke(_hub) public {}

    // EXTERNAL FUNCTIONS

    /// @notice Enable fees for use in the fund
    /// @param _fees The fees to enable
    /// @param _encodedSettings The encoded settings with which a fund uses fees
    function enableFees(address[] calldata _fees, bytes[] calldata _encodedSettings)
        external
        override
    {
        // Access
        require(
            msg.sender == __getHub().FUND_FACTORY(),
            "Only FundFactory can make this call"
        );
        // Sanity check
        require(_fees.length > 0, "enableFees: _fees cannot be empty");
        require(
            _fees.length == _encodedSettings.length,
            "enableFees: array lengths unequal"
        );

        IRegistry registry = __getRegistry();
        for (uint256 i = 0; i < _fees.length; i++) {
            IFee fee = IFee(_fees[i]);
            require(
                registry.feeIsRegistered(address(fee)),
                "enableFees: Fee is not on Registry"
            );
            require(
                !__feeIsEnabled(address(fee)),
                "enableFees: Fee is already enabled"
            );

            // Set fund config on fee
            fee.addFundSettings(_encodedSettings[i]);

            // Add fee
            EnumerableSet.add(enabledFees, address(fee));

            emit FeeEnabled(address(fee), _encodedSettings[i]);
        }
    }

    /// @notice Settle fees for the entire fund
    /// @param _hook The FeeHook for which to settle fees
    /// @return totalSharesDue_ The total amount of shares that should be created for the manager
    /// @dev Gets fees owed by entire fund, while giving the Fee an opportunity to update its state.
    /// Works by minting new fund shares to fund manager.
    function settleFeesForFund(FeeHook _hook)
        external
        override
        onlyShares
        returns (uint256 totalSharesDue_)
    {
        address[] memory fees = getEnabledFees();
        for (uint i = 0; i < fees.length; i++) {
            IFee fee = IFee(fees[i]);
            if (fee.feeHook() == _hook) {
                uint256 sharesDue = fee.settleFeeForFund();
                if (sharesDue == 0) continue;

                totalSharesDue_ = add(totalSharesDue_, sharesDue);
                emit FeeSettledForFund(address(fee), sharesDue);
            }
        }
    }

    /// @notice Settle fees for a single investor
    /// @param _hook The FeeHook for which to settle fees
    /// @param _investor The investor for whom to settle fees
    /// @param _sharesQuantity The quantity of shares for which to settle fees
    /// @return totalSharesDue_ The total amount of shares that should be reallocated to the manager
    /// @dev Gets fees owed by an investor, while giving the Fee an opportunity to update its state.
    /// Works by reallocation from investor to fund manager.
    function settleFeesForInvestor(FeeHook _hook, address _investor, uint256 _sharesQuantity)
        external
        override
        onlyShares
        returns (uint256 totalSharesDue_)
    {
        address[] memory fees = getEnabledFees();
        for (uint i = 0; i < fees.length; i++) {
            IFee fee = IFee(fees[i]);
            if (fee.feeHook() == _hook) {
                uint256 sharesDue = fee.settleFeeForInvestor(_investor, _sharesQuantity);
                if (sharesDue == 0) continue;

                totalSharesDue_ = add(totalSharesDue_, sharesDue);
                emit FeeSettledForInvestor(address(fee), _investor, _sharesQuantity, sharesDue);
            }
        }
    }

    /// @notice Update settings for a fee that is in use in a fund
    /// @param _fee The fee to update
    /// @param _encodedSettings The encoded settings with which a fund uses fees
    function updateFeeSettings(address _fee, bytes calldata _encodedSettings)
        external
        onlyManager
    {
        IFee(_fee).updateFundSettings(_encodedSettings);
    }

    // PUBLIC FUNCTIONS

    /// @notice Get a list of enabled fees
    /// @return An array of enabled fee addresses
    function getEnabledFees() public view returns (address[] memory) {
        return EnumerableSet.enumerate(enabledFees);
    }

    // PRIVATE FUNCTIONS

    /// @dev Helper to check if a fee is enabled for the fund
    function __feeIsEnabled(address _fee) private view returns (bool) {
        return EnumerableSet.contains(enabledFees, _fee);
    }
}

contract FeeManagerFactory {
    function createInstance(address _hub) external returns (address) {
        return address(new FeeManager(_hub));
    }
}
