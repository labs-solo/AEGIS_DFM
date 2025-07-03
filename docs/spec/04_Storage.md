Understood. I will now synthesize all authoritative and supporting project documentation, storage layout tables, interface definitions, and prior drafts to produce the final, canonical Section 4 – Data Model & Storage and Appendix B – Unified Storage Table. This will supersede all prior versions and become the audit-ready reference for VaultManagerCore.

I'll notify you once the final specification is complete and ready for review.


## 4. Data Model & Storage (Layout Freeze)

**VaultManagerCore’s storage layout is now final and frozen through slot 24.** All state variables up to slot 24 remain fixed in position and type – no existing slot has been repacked or repurposed across upgrades. This ensures that data from earlier phases retains the same storage slot in later phases (e.g. the `userVaults` mapping stays at slot 7 from Phase 1 onward). Any new variables in future versions **must be added at slot 25 or higher** to obey Solidity’s append-only invariant. The Phase 7 update (with the Batch-Engine extension) introduced no changes below slot 25, so slots 0–24 can be considered canonical and audit-locked. (Notably, a planned *limit-order nonce* field was **not** added in Phase 5, leaving slots 19–22 unused and reserved.)

### 4.1 Design & Packing Rationale

* **Upgrade-Safe Ordering:** The layout was pre-planned in Phase 1 to accommodate future features without shifting existing slots. New phases only **appended** slots or activated pre-reserved fields, preventing any storage collisions through Phase 7.
* **Hot Fields in Low Slots:** Frequently accessed fields are kept in low-numbered slots for gas efficiency. For example, the governance `owner` address (160 bits) and global `pauseFlags` (96 bits) share slot 0, so a single warm SLOAD fetches both the owner and pause status. This warm-access pattern (EIP-2929) cuts gas for repetitive reads.
* **Packed Scalars:** Small flags and counters are tightly packed into 256-bit words wherever possible. The owner & flags in slot 0 is one example; similarly, two 128-bit counters (`nextVaultId` and `globalNonce`) were packed together in an earlier design (slots now reallocated). Packed storage minimizes unused space and reduces SLOAD count.
* **Isolated Hash Slots:** Large dynamic structures (mappings/arrays) each consume a full slot as a hash root. All per-pool or per-user mappings are placed at distinct slot indices (mostly 6–10 and 12–18) to avoid any unintended overlap. Grouping these mappings in contiguous slots also improves Keccak-256 caching for key lookups.
* **Single-Word Structs:** New composite structures introduced in later phases were designed to fit in a single 32-byte slot when possible. For instance, the `TimelockConfig` (governance parameters) and `MetricsAccumulator` (aggregated metrics) are each exactly 256 bits and occupy one slot each, keeping any `SSTORE` or `SLOAD` for them efficient. This in-place approach avoids an extra hashing indirection that a larger struct or mapping would require.
* **Gas Optimization:** The final layout meets gas targets for all core operations. For example, a simple deposit or withdrawal touches only warm slots (costing \~100 gas each after the first access), and a worst-case 10-action batch executes within \~3.5M gas. By Phase 7, common actions like a warm borrow consume \~125k gas, thanks in part to the packed and cache-friendly storage design (e.g. reusing slot 0 in multiple checks).

### 4.2 Phase-by-Phase Storage Additions (Change Log)

The table below summarizes how each development phase extended the VaultManagerCore storage. Only Phase 2 and beyond introduced new state variables (Tier-2 changes), and all were appended at the end of the prior layout:

* **Phase 1:** Established slots 0–10 for core config and mappings. Some slots were intentionally left unused to serve as placeholders for future features. (For example, slot 5 was reserved for an interest model, and slot 9 for a borrow index, even though lending was not active yet in Phase 1.)
* **Phase 2:** Added `reinvestmentPaused` (`bool` at slot 11) and `lastReinvestment` (`mapping(PoolId ⇒ uint256)` at slot 12) for the automated fee compounding feature. These allow global pausing of fee reinvestment and track the last reinvest timestamp per pool.
* **Phase 3:** Added `totalBorrowShares` (`mapping(PoolId ⇒ uint256)` at slot 13) and `interestRateModel` (`mapping(PoolId ⇒ address)` at slot 14) to support the new borrowing/lending module. Slot 15 was left *unused* as a **soft gap** for any additional lending-related data, but ultimately remained empty in the final design. (Phase 3 also began using the pre-declared `borrowIndices` mapping at slot 9 to track per-pool interest accrual.)
* **Phase 4:** Added `lpPositionMeta` (nested mapping at slot 16) and `positionOwnerIndex` (nested mapping at slot 17) for supporting LP-NFT collateral positions. These structures record metadata for each concentrated liquidity position and index a user’s positions for quick lookup, respectively.
* **Phase 5:** *No new storage slots.* Phase 5 introduced on-vault one-tick limit orders and related controls, but leveraged existing fields (like counters in the `UserVault` struct and the reserved mapping space). A proposed `limitOrderBitmap` did not materialize as a separate storage variable, so **slots 19–22 remained unused** (reserved for potential order-book or TWAP buffers).
* **Phase 6:** Added `badDebt` (`mapping(PoolId ⇒ uint256)` at slot 18) to track any residual debt in a pool after liquidations. This helps governance identify and later cover insolvent positions using Protocol-Owned Liquidity or other means.
* **Phase 7:** Added `TimelockConfig` (struct at slot 23) and `MetricsAccumulator` (struct at slot 24) for governance and monitoring. `TimelockConfig` holds the address of the governance timelock and its delay parameters, while `MetricsAccumulator` stores aggregated system metrics (e.g. total TVL, total debt, POL) and the last block they were updated. Both structs were sized to exactly one slot for gas efficiency.

*(After Phase 7, the **Batch Processing Engine** feature was implemented without introducing new persistent variables, relying on the existing structures. The four hard-reserved slots 19–22 remain available for any future expansion related to batch operation buffers or advanced order book features.)*

### 4.3 Reserved Gaps & Upgrade Rules

To maintain upgrade flexibility, the layout includes both *soft* and *hard* reserved slots:

* **Soft Gaps:** Slot 5 and slot 15 are reserved but considered *reusable* in a future major version, subject to careful audit. These were placeholders (for an interest rate model and an extra Phase 3 field) that ended up unused in the final V2 deployment. They **could** be safely repurposed in a V3 upgrade if needed, since they were never initialized with meaningful data in V2.
* **Hard Gaps:** Slots 19–22 are a contiguous block reserved for anticipated features like order-book state or time-weighted average price buffers. These four slots are marked *hard-reserved*, meaning **they should never be reused** in-place in any upgrade. Using them for new variables would risk confusion with any deployments that expected them to remain empty. Only a full storage migration (e.g. deploying a new contract and transferring state) would allow repurposing slots 19–22.
* **Append-Only Rule:** All future additions **must start at slot 25 or above**. Under no circumstances should a new variable be inserted into slots 0–24 or into the middle of any existing struct. Moreover, any new multi-field word should pack its fields from the least-significant bits upward (right-to-left) without altering the higher-order bits of that slot.
* **Verification:** A storage layout diff tool (CI “slot-collision” check) is run before each deployment or merge to ensure compatibility. Any deviation from the expected layout (e.g. a moved or resized variable) is treated as a critical error. This enforces that upgrades cannot accidentally overwrite existing data. Manual review of the Solidity `--storage-layout` compiler output for VaultManagerCore is also part of the audit process to guarantee alignment with this specification.

### 4.4 Deprecations (Legacy Layout Artifacts)

The following legacy design documents and tables are **superseded** by this final specification and will be archived for reference:

* **`appendix_b_p1.md`:** Original Phase 1 storage map (obsolete after unifying the layout).
* **`contracts_p2.md`:** Early draft of the storage layout from Phase 2 (no longer authoritative).
* *Temporary tables in other Tier-3 specs* – Any interim storage diagrams in older phase specs (e.g. in Phase 3 or Phase 5 documentation) should be considered outdated. The unified table in Appendix B is now the source of truth.

These deprecated materials remain available only for historical regression tests. All new documentation and audits should refer to the unified storage layout going forward.

