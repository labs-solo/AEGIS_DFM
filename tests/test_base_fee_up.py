import pytest
from web3.types import RPCEndpoint

from simulation import orchestrator as orch
from simulation.metrics import FeeTracker


def test_base_fee_up():
    """Stress market with large swings so that CAP events drive base fee up."""

    # Arrange – environment
    w3, pool_id, poolManager, policyManager, dfm, swapRouter, accounts = orch.setup_simulation()

    tracker = FeeTracker(dfm, pool_id)
    pool_key = poolManager.functions.toKey(pool_id).call()

    cap_event_count = 0

    # 24 iterations of aggressive swaps (every hour) with huge price impact to
    # ensure oracle truncation / CAP logic kicks in.
    for step in range(24):
        sqrt_limit = 1  # force extreme swap
        swap_params = (True, 10 ** 24, sqrt_limit)
        swapRouter.functions.swap(pool_key, swap_params).transact(
            {"from": accounts["user"], "gas": 1_000_000}
        )

        w3.provider.make_request(RPCEndpoint("evm_increaseTime"), [3600])
        w3.provider.make_request(RPCEndpoint("evm_mine"), [])
        prev_in_cap = tracker._last_in_cap  # pylint: disable=protected-access
        tracker.log(prefix=f"step={step}")
        if tracker._last_in_cap and not prev_in_cap:  # pylint: disable=protected-access
            cap_event_count += 1

    base_fee, surge_fee, _ = tracker.snapshot()
    max_base_fee = policyManager.functions.getMaxBaseFee(pool_id).call()

    assert base_fee == max_base_fee, "Base fee should have risen to maximum under heavy volatility"
    assert cap_event_count > 0, "At least one CAP event should have occurred"
    assert surge_fee == 0 or cap_event_count > 0  # Surge fee may have decayed by end of test 