import pytest
from web3.types import RPCEndpoint

from simulation import orchestrator as orch
from simulation.metrics import FeeTracker


def test_base_fee_up():
    """Stress market with large swings so that CAP events drive base fee up."""

    # Arrange – environment
    w3, pool_id, pool_key, poolManager, policyManager, dfm, swapRouter, accounts = orch.setup_simulation()

    tracker = FeeTracker(dfm, pool_id)

    cap_event_count = 0

    # 24 iterations of aggressive swaps (every hour) with huge price impact to
    # ensure oracle truncation / CAP logic kicks in.
    for step in range(24):
        sqrt_limit = 1  # force extreme swap
        swap_params = {
            "zeroForOne": True,
            "amountSpecified": 10 ** 24,
            "sqrtPriceLimitX96": sqrt_limit
        }
        options = (False, False)  # (unwrap WETH, pay in link)
        data = b""
        swapRouter.functions.swap(pool_key, swap_params, options, data).transact(
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

    # Flush CSV outputs
    tracker.finalize()

    import csv, os
    results_dir = os.path.join(os.path.dirname(__file__), '..', 'simulation', 'results')
    fee_csv = os.path.join(results_dir, 'fee_and_cap_metrics.csv')
    cap_csv = os.path.join(results_dir, 'cap_event_log.csv')

    # Both CSVs should exist
    assert os.path.isfile(fee_csv), "Daily fee metrics CSV not generated"
    assert os.path.isfile(cap_csv), "CAP event log CSV not generated"

    with open(fee_csv, newline='') as f:
        rows = list(csv.DictReader(f))
        assert len(rows) == 1  # one simulated day
        assert int(rows[0]['CapEventCount']) >= cap_event_count >= 1
        assert int(rows[0]['TotalSurgeFeeCollected']) >= 0

    with open(cap_csv, newline='') as f:
        lines = list(csv.reader(f))
        # header + at least one CAP event row
        assert len(lines) >= 2 