pragma solidity 0.6.8;

import "../../../dependencies/DSMath.sol";
import "../../../registry/Registry.sol";
import "../../hub/Hub.sol";
import "../../hub/Spoke.sol";
import "../../hub/SpokeCallee.sol";
import "../IFee.sol";

/// @title FeeBase Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice Abstract base contract for fees
abstract contract FeeBase is IFee, DSMath, SpokeCallee {
    address public REGISTRY;

    modifier onlyFeeManager {
        require(__isFeeManager(msg.sender), "Only FeeManger can make this call");
        _;
    }

    constructor(address _registry) public {
        REGISTRY = _registry;
    }

    /// @notice Update the fee settings for a fund
    /// @dev Disallowed by default, but can be overriden by child
    function updateFundSettings(bytes calldata) external virtual override {
        revert("updateFundSettings: Updates not allowed for this fee");
    }

    /// @notice Helper to determine whether an address is a valid FeeManager component
    function __isFeeManager(address _who) internal view returns (bool) {
        // 1. Is valid Spoke of a Registered fund
        // 2. Is the fee manager of the registered fund
        try Spoke(_who).HUB() returns (address hub) {
            return Registry(REGISTRY).fundIsRegistered(hub) && __getFeeManager(hub) == _who;
        }
        catch {
            return false;
        }
    }
}
