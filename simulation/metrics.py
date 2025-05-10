from __future__ import annotations

import csv
from pathlib import Path
from web3.contract import Contract
import os


class FeeTracker:
    """Lightweight helper to observe Dynamic Fee Manager state during tests/simulation.

    It prints fee state updates, tracks CAP event boundaries, and writes CSV
    outputs (per-day fee metrics & CAP event log) under `simulation/results/`.
    """

    def __init__(
        self,
        dfm_contract: Contract,
        pool_id: int,
        *,
        results_dir: str | Path | None = None,
        steps_per_day: int = 288,
    ) -> None:
        self._dfm = dfm_contract
        self._pool_id = pool_id
        self._last_in_cap: bool = False

        self._results_dir = Path(results_dir) if results_dir else Path(__file__).parent / "results"
        self._results_dir.mkdir(parents=True, exist_ok=True)

        self._steps_per_day = steps_per_day
        self._step_counter: int = 0
        self._swap_logs: list[dict[str, int]] = []
        self._cap_event_start: int | None = None
        self._cap_events: list[tuple[int, int]] = []  # (start_step, end_step)
        self._finalized: bool = False

        # ---------------- Phase 3 additions ----------------
        # Track granular fee components per swap so that extended simulations
        # (e.g. dual-pool arbitrage tests) can make assertions about collected
        # fees without having to parse on-chain events post-hoc.
        # Units used: **percentage** (not ppm) so that tests can express human
        # readable values such as 0.30 for a 0.30 % fee tier.
        self.base_fees: list[float] = []   # base component per swap (percent)
        self.surge_fees: list[float] = []  # surge component per swap (percent)
        self.fees: list[float] = []        # total fee per swap (percent)

        # CAP event registry used by Phase 3 tests
        self.cap_events: list[dict] = []   # Each item: {"time": int, ...details}

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def snapshot(self) -> tuple[int, int, int]:
        """Return the current (base_fee_ppm, surge_fee_ppm, total_fee_ppm)."""
        base_fee, surge_fee = self._dfm.functions.getFeeState(self._pool_id).call()
        return base_fee, surge_fee, base_fee + surge_fee

    def log(self, prefix: str | None = None) -> None:
        """Record a per-swap snapshot and print a concise log line."""
        base_fee, surge_fee, total_fee = self.snapshot()
        in_cap = surge_fee > 0

        msg = f"BaseFee={base_fee}ppm, SurgeFee={surge_fee}ppm, TotalFee={total_fee}ppm"
        if prefix:
            msg = f"{prefix} {msg}"
        print(msg)

        # Detect CAP event boundaries for human readability
        if in_cap and not self._last_in_cap:
            print(">> CAP event START")
        elif not in_cap and self._last_in_cap:
            print(">> CAP event END")

        # Track swap-level data used for CSV aggregation later
        self._swap_logs.append(
            {
                "Step": self._step_counter,
                "InCAP": int(in_cap),
                "BaseFeePPM": base_fee,
                "SurgeFeePPM": surge_fee,
                "TotalFeePPM": total_fee,
            }
        )

        # Record CAP event windows
        if in_cap and self._cap_event_start is None:
            self._cap_event_start = self._step_counter
        elif not in_cap and self._cap_event_start is not None:
            self._cap_events.append((self._cap_event_start, self._step_counter))
            self._cap_event_start = None

        self._last_in_cap = in_cap
        self._step_counter += 1

    # ------------------------------------------------------------------
    # CSV output helpers
    # ------------------------------------------------------------------

    def _write_outputs(self) -> None:
        """Generate `fee_and_cap_metrics.csv` and `cap_event_log.csv`."""
        # Aggregate per-day fee metrics
        daily_rows: list[dict[str, int]] = []
        num_days = (len(self._swap_logs) + self._steps_per_day - 1) // self._steps_per_day or 1
        for day in range(num_days):
            start = day * self._steps_per_day
            end = min((day + 1) * self._steps_per_day, len(self._swap_logs))
            slice_logs = self._swap_logs[start:end]
            if not slice_logs:
                continue
            base_sum = sum(r["BaseFeePPM"] for r in slice_logs)
            surge_sum = sum(r["SurgeFeePPM"] for r in slice_logs)
            total_sum = sum(r["TotalFeePPM"] for r in slice_logs)
            cap_events_in_day = sum(1 for s, _ in self._cap_events if start <= s < end)
            daily_rows.append(
                {
                    "Date": f"Day {day + 1}",
                    "BaseFeePPM": slice_logs[-1]["BaseFeePPM"],
                    "CapEventCount": cap_events_in_day,
                    "TotalBaseFeeCollected": base_sum,
                    "TotalSurgeFeeCollected": surge_sum,
                    "TotalFeeCollected": total_sum,
                }
            )

        fee_metrics_file = self._results_dir / "fee_and_cap_metrics.csv"
        with fee_metrics_file.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=daily_rows[0].keys()) if daily_rows else None
            if writer:
                writer.writeheader()
                writer.writerows(daily_rows)

        # Detailed CAP event log
        if self._cap_events:
            cap_file = self._results_dir / "cap_event_log.csv"
            with cap_file.open("w", newline="") as f:
                writer = csv.writer(f)
                writer.writerow(["StartStep", "EndStep", "DurationSteps"])
                for start_step, end_step in self._cap_events:
                    writer.writerow([start_step, end_step, end_step - start_step])

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def finalize(self) -> None:
        """Flush all buffered logs to disk exactly once."""
        if not self._finalized:
            # If a CAP event is still open, close it using the current step count
            if self._cap_event_start is not None:
                self._cap_events.append((self._cap_event_start, self._step_counter))
                self._cap_event_start = None
            self._write_outputs()
            self._finalized = True

    def __del__(self):
        try:
            self.finalize()
        except Exception:  # pragma: no cover – best-effort during interpreter shutdown
            pass

    # ------------------------------------------------------------------
    # Phase 3 public helpers (non-intrusive for Phase 2 callers)
    # ------------------------------------------------------------------

    def record_swap(self, base_fee: float, applied_fee: float) -> None:  # noqa: D401
        """Record the fee breakdown of a swap.

        Parameters
        ----------
        base_fee : float
            Base liquidity-provider fee (percentage, e.g. 0.30 for 0.30 %).
        applied_fee : float
            Actual fee applied once surge component is included – must be
            >= *base_fee*.
        """

        surge_fee = max(applied_fee - base_fee, 0.0)
        self.base_fees.append(base_fee)
        self.surge_fees.append(surge_fee)
        self.fees.append(applied_fee)

    def record_cap_event(self, timestamp: int, details: dict | None = None) -> None:  # noqa: D401
        """Register that a CAP event was triggered at *timestamp* (minutes).

        Additional details (like the pool prices) can be attached via *details*.
        The structure is kept intentionally flexible for downstream analysis.
        """

        payload = {"time": timestamp}
        if details:
            payload.update(details)
        self.cap_events.append(payload)

    def save_csv(self, filepath: str | os.PathLike) -> None:
        """Write a compact CSV with base/surge/total fee history.

        This is separate from the legacy `_write_outputs()` data because Phase 3
        simulations may wish to dump a single CSV rather than the two legacy
        outputs.  The legacy writer is still invoked via :py:meth:`finalize` so
        older tests remain unaffected.
        """

        Path(filepath).parent.mkdir(parents=True, exist_ok=True)
        with open(filepath, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["swap_index", "base_fee", "surge_fee", "total_fee"])
            for idx, (b, s, t) in enumerate(zip(self.base_fees, self.surge_fees, self.fees)):
                writer.writerow([idx, b, s, t]) 