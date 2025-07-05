> v1.2.1-rc3
>
> # 0 Glossary
>
> - **CF_init / CF_maint** — collateral factor at initialization vs maintenance (18-dec fixed-point).
> - **LTV(user)** = Σ(debtValue) / Σ(collateralValue) per user, in base currency.
> - **On-chain identifiers**
>   - **bonus** — liquidation incentive percentage (default 5 %).
>   - **pid** — pool ID for liquidity positions.
>   - **pairKey** — keccak(token0, token1, feeTier).
>   - **swapPath** — ABI-encoded path understood by the DEX router.
> - **Share (Liquidity Unit)** — Minted when liquidity is added and burned to borrow. Each share equals a pro rata slice of pool liquidity. Its USD price is \(\sqrt{token0\times token1}/totalShares\); see [Lemma 5.2-A](05_Functional_Specs.md#lemma-5-2-a). Those same units measure outstanding debt so collateral and liabilities use one scale.
> - **shareIndex / borrowIndex** — cumulative indices translating assets and shares.
> - **warm / cold SLOAD** — first slot access is cold (≈ 2 100 gas surcharge).
> - “cold” vs “warm” gas figures reference `gas_p3.md`; ±5 % variance allowed on future EVM upgrades.
