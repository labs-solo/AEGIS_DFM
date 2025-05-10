import importlib

import pytest

# Import orchestrator afresh for each test so that module-level cache is reset
# between tests that might rely on fresh simulation state.


def _load_orchestrator():
    import simulation.orchestrator as orch
    # Reload to reset module-level globals between tests if needed
    importlib.reload(orch)
    orch.main()  # ensure simulation ran
    return orch


def test_arbitrage_prices_converge():
    orch = _load_orchestrator()
    ft = orch.fee_tracker

    assert ft is not None, "fee_tracker should be initialised by orchestrator.main()"
    # Prices should converge to within 0.1 % after arbitrage operations.
    dynamic = ft.last_price_dynamic
    baseline = ft.last_price_baseline
    assert abs(dynamic - baseline) / baseline < 1e-3


def test_cap_events_triggered():
    orch = _load_orchestrator()
    ft = orch.fee_tracker

    cap_count = len(ft.cap_events)
    assert cap_count >= 1, "At least one CAP event expected during simulation"

    # Ensure surge fee positive during each recorded CAP event swap
    for event in ft.cap_events:
        # Compute corresponding swap index (5-minute interval index)
        idx = int(event["time"] / 5)
        assert ft.surge_fees[idx] > 0


def test_dynamic_pool_collects_more_fees():
    orch = _load_orchestrator()
    ft = orch.fee_tracker

    dynamic_total = sum(ft.fees)
    baseline_total = 0.30 * len(ft.fees)

    # Dynamic pool should collect at least 10 % more fees than baseline
    assert float(dynamic_total) >= float(baseline_total * 1.1) 