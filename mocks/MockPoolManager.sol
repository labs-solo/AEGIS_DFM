import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IExtsload} from "../../src/interfaces/IExtsload.sol";

contract MockPoolManager is IExtsload {
    /// @dev Per-pool tick storage keyed by PoolId.unwrap(pid)
    mapping(bytes32 => int24) private _ticks;

    /* ─────────────── Test-only helper ─────────────── */
    function setTick(PoolId pid, int24 newTick) external {
        _ticks[PoolId.unwrap(pid)] = newTick;
    }

    /* minimal subset expected by StateLibrary */
    function getSlot0(PoolId pid) external view returns (uint160, int24, uint16, uint8) {
        // Return 0 for sqrtPriceX96, observationIndex, and feeGrowthOutside{0/1}X128
        // Return the stored tick for the given pool
        return (0, _ticks[PoolId.unwrap(pid)], 0, 0);
    }

    function getLiquidity(PoolId) external pure returns (uint128) { return 0; }
} 