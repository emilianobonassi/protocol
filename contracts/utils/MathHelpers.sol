// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;

import "../dependencies/DSMath.sol";

/// @title MathHelpers Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice Helper function for common math operations
contract MathHelpers is DSMath {
    /// @dev Calculates a proportional value relative to a known ratio.
    /// For use in calculating a missing expected fill amount
    /// based on an asset pair's price
    function __calcRelativeQuantity(
        uint256 _quantity1,
        uint256 _quantity2,
        uint256 _relativeQuantity1
    )
        internal
        pure
        returns (uint256 relativeQuantity2_)
    {
        relativeQuantity2_ = mul(_relativeQuantity1, _quantity2) / _quantity1;
    }
}
