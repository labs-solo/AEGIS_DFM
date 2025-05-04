// test/unit/SharedDeployLib.t.sol
pragma solidity ^0.8.26;
import "forge-std/Test.sol";
import "../../test/utils/SharedDeployLib.sol"; // Adjusted path

contract SharedDeployLib_PredictEqDeploy is Test {
    function test_predictEqualsDeploy() public {
        bytes memory args;
        bytes memory code = hex"00"; // dummy 1-byte runtime
        bytes32 SALT = keccak256("unit");
        address predicted = SharedDeployLib.predictDeterministicAddress(
            address(this), SALT, code, args
        );
        address deployed = SharedDeployLib.deployDeterministic(
            address(this),
            SALT, code, args
        );
        assertEq(predicted, deployed);
    }
} 