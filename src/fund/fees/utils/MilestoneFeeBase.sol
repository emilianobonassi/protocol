pragma solidity 0.6.8;

import "./FeeBase.sol";

/// @title MilestoneFeeBase Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice Abstract base contract for Milestone-based fees
abstract contract MilestoneFeeBase is FeeBase {
    constructor(address _registry) public FeeBase(_registry) {}

    /// @notice Provides a constant string identifier for a policy
    function feeHook() external view override returns (IFeeManager.FeeHook) {
        return IFeeManager.FeeHook.Milestone;
    }

    /// @dev Helper to calculate shares due, taking inflation into account
    function __calcSharesDueWithInflation(uint256 _rawSharesDue, uint256 _sharesSupply)
        internal
        pure
        returns (uint256)
    {
        return mul(_rawSharesDue, _sharesSupply) / sub(_sharesSupply, _rawSharesDue);
    }
}
