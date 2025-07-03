```markdown
# AEGIS V2 Unified Vault — **Final Specification**

> **Version:** `vFinalSpec-draft` &nbsp;|&nbsp; **Last Updated:** 2025-07-02  
> **License:** **Business Source License 1.1** (see [`LICENSE`](LICENSE)) &nbsp;|&nbsp; **Licensor:** Solo Labs, Inc.  
> **Status:** _In active drafting — PRs welcome_

AEGIS V2 introduces a **single, upgrade-safe vault**, a deterministic **batch-processing engine**, and a full on-chain **limit-order system** to Uniswap V4—while remaining 100 % backward-compatible with AEGIS DFM.  
This repository contains the **canonical, implementation-ready specification** (plus gas tables, UML, and migration guides) that smart-contract engineers, auditors, and protocol governors should reference.

*Open the spec at **`docs/FinalSpec.md`** for a top-to-bottom tour.*

---

The `docs/` folder is pure Markdown—**no build chain required** for casual browsing on GitHub.
Running the commands above ensures diagrams + tables are regenerated and all references resolve.

---

## 🧭 Key Spec Sections

| Section                        | What you’ll find                                          |
| ------------------------------ | --------------------------------------------------------- |
| **1. Executive Summary**       | Goals, non-negotiable gas targets, compatibility promises |
| **4. Storage Layout**          | Complete slot map (0-∞) including batch-engine additions  |
| **5. External Interfaces**     | Solidity ABIs with events & custom errors                 |
| **6. Batch Processing Engine** | Action-ID table, risk-ordered dispatcher pseudocode       |
| **10. Risk & Invariants**      | Formal INV-x proofs and Foundry test harness              |
| **14. Deployment & Ops Guide** | Keeper duties, oracle cadence, gas-limit tuning           |

(Full table of contents lives inside **`docs/FinalSpec.md`**.)

---

## 🔒 License & Attribution

This repository’s **source files constitute the “Licensed Work” under the Business Source License 1.1** with the following parameters:

| Parameter                    | Value                                                  |
| ---------------------------- | ------------------------------------------------------ |
| **Licensor**                 | Solo Labs, Inc                                         |
| **Licensed Work**            | “AEGIS DFM Hook” "AEGIS V2" (all source files)         |
| **Additional Use Grant**     | See § 3 (“Evaluation Period”) of the license text      |
| **Initial Publication Date** | 2025-05-01                                             |
| **Change Date**              | 2029-05-01                                             |
| **Change License**           | GNU General Public License v3.0 or later (GPL-3.0+)    |

Until the Change Date, **commercial or main-net production use requires a separate license from Solo Labs, Inc**.
After 2029-05-01 the Licensed Work will automatically re-license under GPL-3.0+.
Full legal text is provided in [`LICENSE`](LICENSE).

---

## 📣 Contact

* **Spec lead:** Bryan Gross
