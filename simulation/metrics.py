from __future__ import annotations

from web3.contract import Contract


class FeeTracker:
    """Lightweight helper to observe Dynamic Fee Manager state during tests/simulation.

    It merely prints fee state transitions and tracks when CAP events start/end so
    that tests can verify the behaviour without having to parse on-chain events.
    """

    def __init__(self, dfm_contract: Contract, pool_id: int):
        self._dfm = dfm_contract
        self._pool_id = pool_id
        self._last_in_cap: bool = False

    # ------------------------------------------------------------------
    # Public helpers
    # ------------------------------------------------------------------

    def snapshot(self) -> tuple[int, int, int]:
        """Return (base_fee_ppm, surge_fee_ppm, total_fee_ppm)."""
        base_fee, surge_fee = self._dfm.functions.getFeeState(self._pool_id).call()
        return base_fee, surge_fee, base_fee + surge_fee

    def log(self, prefix: str | None = None) -> None:
        base_fee, surge_fee, total_fee = self.snapshot()
        in_cap = surge_fee > 0

        msg = f"BaseFee={base_fee}ppm, SurgeFee={surge_fee}ppm, TotalFee={total_fee}ppm"
        if prefix:
            msg = f"{prefix} {msg}"
        print(msg)

        # CAP event edge detection for developer visibility
        if in_cap and not self._last_in_cap:
            print(">> CAP event START")
        elif not in_cap and self._last_in_cap:
            print(">> CAP event END")

        self._last_in_cap = in_cap 