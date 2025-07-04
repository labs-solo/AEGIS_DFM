> v1.2.1-rc3
>
> # 0 Glossary
>
> - **CF_init / CF_maint** — collateral factor at initialization vs maintenance (18-dec fixed-point).
> - **shareIndex / borrowIndex** — cumulative indices translating assets and shares.
> - **LTV(user)** = Σ(debtValue) / Σ(collateralValue) per user, in base currency.
> - **warm / cold SLOAD** — first slot access is cold (≈ 2 100 gas surcharge).
> - **bonus** — liquidation incentive percentage (default 5 %).
> - **pid** — pool ID for liquidity positions.
> - **pairKey** — keccak(token0, token1, feeTier).
> - **swapPath** — ABI-encoded path understood by the DEX router.
> - “cold” vs “warm” gas figures reference `gas_p3.md`; ±5 % variance allowed on future EVM upgrades.
