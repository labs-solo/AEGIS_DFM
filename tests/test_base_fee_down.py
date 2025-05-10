import math

import pytest
from web3.types import RPCEndpoint

from simulation import orchestrator as orch
from simulation.metrics import FeeTracker


def test_base_fee_down():
    """Run a short calm-market simulation – base fee should decay to minimum."""

    # Arrange – spin up environment
    w3, pool_id, poolManager, policyManager, dfm, swapRouter, accounts = orch.setup_simulation()

    tracker = FeeTracker(dfm, pool_id)
    pool_key = poolManager.functions.toKey(pool_id).call()

    # We'll do 24 hourly swaps with VERY small price impact to mimic calm market.
    # The on-chain DFM contract has its own internal fee-update cadence; here we
    # simply progress time in Anvil so that fee logic can update each hour.

    for step in range(24):
        sqrt_limit = int((math.sqrt(1.001)) * (1 << 96))  # ~0.1% move cap
        swap_params = (False, 10 ** 18, sqrt_limit)
        swapRouter.functions.swap(pool_key, swap_params).transact(
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