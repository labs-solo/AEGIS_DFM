import math
import csv
import os

import pytest
from web3.types import RPCEndpoint

from simulation import orchestrator as orch
from simulation.metrics import FeeTracker


def test_base_fee_down():
    """Run a short calm-market simulation – base fee should decay to minimum."""

    # Arrange – spin up environment
    w3, pool_id, pool_key, poolManager, policyManager, dfm, swapRouter, accounts = orch.setup_simulation()

    tracker = FeeTracker(dfm, pool_id)

    # We'll do 24 hourly swaps with VERY small price impact to mimic calm market.
    # The on-chain DFM contract has its own internal fee-update cadence; here we
    # simply progress time in Anvil so that fee logic can update each hour.

    for step in range(24):
        sqrt_limit = int((math.sqrt(1.001)) * (1 << 96))  # ~0.1% move cap
        swap_params = {
            "zeroForOne": False,
            "amountSpecified": 10 ** 18,
            "sqrtPriceLimitX96": sqrt_limit
        }
        options = (False, False)  # (unwrap WETH, pay in link)
        data = b""
        swapRouter.functions.swap(pool_key, swap_params, options, data).transact(
            {"from": accounts["user"], "gas": 1_000_000}
        )

        # advance blockchain clock 1 hour so that fee algorithm has chance to decay
        w3.provider.make_request(RPCEndpoint("evm_increaseTime"), [3600])
        w3.provider.make_request(RPCEndpoint("evm_mine"), [])
        tracker.log(prefix=f"step={step}")

    # Assert – base fee at min, no surge fee active
    base_fee, surge_fee, _ = tracker.snapshot()
    min_base_fee = policyManager.functions.getMinBaseFee(pool_id).call()

    assert surge_fee == 0, "Surge fee should never activate in calm market"
    assert base_fee == min_base_fee, "Base fee should decay to configured minimum"

    # Finalize tracker to flush CSV outputs
    tracker.finalize()

    # Verify results CSV files exist and contain expected data
    results_dir = os.path.join(os.path.dirname(__file__), '..', 'simulation', 'results')
    fee_csv = os.path.join(results_dir, 'fee_and_cap_metrics.csv')
    cap_csv = os.path.join(results_dir, 'cap_event_log.csv')

    assert os.path.isfile(fee_csv), "Daily fee metrics CSV was not generated"

    with open(fee_csv, newline='') as f:
        rows = list(csv.DictReader(f))
        # Expect exactly 1 day of data for this short test
        assert len(rows) == 1
        assert int(rows[0]['CapEventCount']) == 0

    # cap_event_log.csv may be absent or empty for calm market; both are acceptable
    if os.path.exists(cap_csv):
        with open(cap_csv, newline='') as f:
            lines = list(csv.reader(f))
            # Only header row if file exists
            assert len(lines) <= 1 