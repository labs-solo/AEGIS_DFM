> v1.2.1-rc3
>
> # 8 Upgrade & Ops Guide
>
> ### 8.2 On-chain Config Matrix
>
> | Parameter        | Contract          | Change Path         | Selector                                        | Pause Bit |
> | ---------------- | ----------------- | ------------------- | ----------------------------------------------- | --------- |
> | collateralFactor | PoolPolicyManager | governor → timelock | `updateCollateralFactor(bytes32,uint16,uint16)` | PAUSE_GOV |
> | borrowRateModel  | PoolPolicyManager | governor → timelock | `setInterestModel(bytes32,address)`             | PAUSE_GOV |
>
> ### Forge Deployment Snippet
>
> ```bash
> forge create2 --rpc-url <url> --private-key <key> \
>   src/VaultManagerCore.sol:VaultManagerCore \
>   --constructor-args <args> --salt AEGIS_LIB_V1
> ```
>
> EOF
