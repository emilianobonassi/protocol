// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;
pragma experimental ABIEncoderV2;

/// @title FeeManager Interface
/// @author Melon Council DAO <security@meloncoucil.io>
interface IFeeManager {
    enum FeeHook { None, BuyShares, Milestone, SellShares }

    function enableFees(address[] calldata, bytes[] calldata) external;
    function settleFeesForFund(FeeHook) external returns (uint256);
    function settleFeesForInvestor(FeeHook, address, uint256) external returns (uint256);
}

/// @title FeeManagerFactory Interface
/// @author Melon Council DAO <security@meloncoucil.io>
interface IFeeManagerFactory {
    function createInstance(address) external returns (address);
}
