import os
import subprocess
import time
import json
import math
import shutil
from pathlib import Path
from typing import Tuple, Optional

from web3 import Web3
from web3.types import RPCEndpoint, RPCResponse
from web3.contract.contract import Contract
from eth_typing import URI
from eth_abi import encode

# -------------------------------------------------------------
#  Constants & helpers
# -------------------------------------------------------------
WORKSPACE = Path(__file__).resolve().parent.parent
ARTIFACTS = WORKSPACE / "out"
# Flags required by Spot.getHookPermissions(): AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA
REQUIRED_HOOK_FLAGS = 0x10C4  # see @uniswap/v4-core/libraries/Hooks.sol
HOOK_MASK = (1 << 14) - 1

# Custom POA middleware for Anvil
class PoaMiddleware:
    def __init__(self, w3):
        self.w3 = w3

    def wrap_make_request(self, make_request):
        def middleware(method, params):
            response = make_request(RPCEndpoint(method), params)
            # Add required jsonrpc field if missing
            if isinstance(response, dict) and "jsonrpc" not in response and "result" in response:
                response["jsonrpc"] = "2.0"
                response["id"] = 1
            # Handle block responses
            if method in ("eth_getBlockByNumber", "eth_getBlockByHash") and "result" in response:
                result = response["result"]
                if result and "difficulty" not in result:
                    result["difficulty"] = "0x0"
                    result["totalDifficulty"] = "0x0"
            return response
        return middleware

def poa_middleware(w3):
    return PoaMiddleware(w3)

# --- Solidity source for a minimal CREATE2 factory ---
CREATE2_FACTORY_SOURCE = """
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
contract Create2Factory {
    /**
     * Deploy `bytecode` using CREATE2 with `salt`.
     * Reverts if deployment fails or contract already exists.
     */
    function deploy(bytes memory bytecode, bytes32 salt) external returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(addr)) { revert(0, 0) }
        }
    }
}
"""

# -------------------------------------------------------------
#  Utility: load artefact helpers
# -------------------------------------------------------------

def load_artifact(name: str):
    """Return ABI + bytecode for a given file under /out."""
    path = ARTIFACTS / name
    if not path.exists():
        raise FileNotFoundError(f"Artifact {name} not found under /out. Did you run `forge build`?")
    with open(path) as f:
        data = json.load(f)
    return data["abi"], data["bytecode"]["object"]


def compile_create2_factory(w3: Web3) -> Contract:
    """Compile & deploy the minimal Create2Factory if not deployed yet."""
    try:
        import solcx  # type: ignore
    except ImportError as exc:
        raise RuntimeError("solcx package required to compile Create2Factory. Install via `pip install py-solc-x`. ") from exc

    solcx.install_solc("0.8.17")
    compiled = solcx.compile_source(
        CREATE2_FACTORY_SOURCE,
        output_values=["abi", "bin"],
        solc_version="0.8.17",
    )
    (contract_id, contract_interface), = compiled.items()
    factory_contract = w3.eth.contract(
        abi=contract_interface["abi"], bytecode=contract_interface["bin"]
    )
    tx = factory_contract.constructor().build_transaction({
        "from": w3.eth.accounts[0],
        "gas": 1_500_000,
    })
    tx_hash = w3.eth.send_transaction(tx)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    return w3.eth.contract(address=receipt.contractAddress, abi=contract_interface["abi"])


# -------------------------------------------------------------
#  Hook-address mining (Python port of Uniswap HookMiner)
# -------------------------------------------------------------

def find_salt_for_flags(deployer: str, creation_code: bytes, flags: int, max_loop: int = 200_000) -> Tuple[int, str]:
    """Return (salt, predicted_addr) such that addr & MASK == flags."""
    for salt in range(max_loop):
        salt_bytes = salt.to_bytes(32, byteorder="big")
        addr_bytes = Web3.keccak(b"\xff" + Web3.to_bytes(hexstr=deployer) + salt_bytes + Web3.keccak(creation_code))[-20:]
        addr_int = int.from_bytes(addr_bytes, "big")
        if addr_int & HOOK_MASK == flags:
            return salt, Web3.to_checksum_address(addr_bytes.hex())
    raise RuntimeError("Failed to find suitable salt for hook address within max_loop")


# -------------------------------------------------------------
#  Main orchestrator
# -------------------------------------------------------------

def main():
    # 0. Connect (or start) local Anvil
    anvil_uri = os.getenv("ANVIL_URI", "http://127.0.0.1:8545")
    if not Web3(Web3.HTTPProvider(anvil_uri)).is_connected():
        # Spawn anvil in the background
        anvil_proc = subprocess.Popen(["anvil", "--port", "8545"], stdout=subprocess.PIPE)
        time.sleep(3)
        if not Web3(Web3.HTTPProvider(anvil_uri)).is_connected():
            raise RuntimeError("Failed to connect to local anvil node.")
    w3 = Web3(Web3.HTTPProvider(anvil_uri))
    # Anvil uses PoA; add middleware so eth_getBlock works correctly under web3.py >= 6
    w3.middleware_onion.inject(poa_middleware, layer=0)

    deployer = w3.eth.accounts[0]
    user = w3.eth.accounts[1]
    lp_provider = w3.eth.accounts[2]

    print("Connected to Anvil – chainId:", w3.eth.chain_id)

    # ---------------------------------------------------------
    # 1. Load required artefacts (PoolManager, MockERC20, etc.)
    # ---------------------------------------------------------
    abi_pm, byte_pm = load_artifact("PoolManager.sol/PoolManager.json")
    abi_token, byte_token = load_artifact("MockERC20.sol/MockERC20.json")
    abi_policy, byte_policy = load_artifact("PoolPolicyManager.sol/PoolPolicyManager.json")
    abi_oracle, byte_oracle = load_artifact("TruncGeoOracleMulti.sol/TruncGeoOracleMulti.json")
    abi_lm, byte_lm = load_artifact("FullRangeLiquidityManager.sol/FullRangeLiquidityManager.json")
    abi_dfm, byte_dfm = load_artifact("DynamicFeeManager.sol/DynamicFeeManager.json")
    abi_spot, byte_spot = load_artifact("Spot.sol/Spot.json")
    abi_swapT, byte_swapT = load_artifact("PoolSwapTest.sol/PoolSwapTest.json")
    abi_liqT, byte_liqT = load_artifact("PoolModifyLiquidityTest.sol/PoolModifyLiquidityTest.json")

    PoolManager = w3.eth.contract(abi=abi_pm, bytecode=byte_pm)
    MockERC20 = w3.eth.contract(abi=abi_token, bytecode=byte_token)
    PolicyManager = w3.eth.contract(abi=abi_policy, bytecode=byte_policy)
    Oracle = w3.eth.contract(abi=abi_oracle, bytecode=byte_oracle)
    LiquidityManager = w3.eth.contract(abi=abi_lm, bytecode=byte_lm)
    DynamicFeeManager = w3.eth.contract(abi=abi_dfm, bytecode=byte_dfm)
    SpotHook = w3.eth.contract(abi=abi_spot, bytecode=byte_spot)
    SwapRouterC = w3.eth.contract(abi=abi_swapT, bytecode=byte_swapT)
    LPRouterC = w3.eth.contract(abi=abi_liqT, bytecode=byte_liqT)

    # ---------------------------------------------------------
    # 2. Deploy PoolManager
    # ---------------------------------------------------------
    tx_hash = PoolManager.constructor(Web3.to_checksum_address("0x" + "00" * 20)).transact({"from": deployer})
    pool_manager_addr = w3.eth.wait_for_transaction_receipt(tx_hash).contractAddress
    poolManager = w3.eth.contract(address=pool_manager_addr, abi=abi_pm)
    print("PoolManager:", pool_manager_addr)

    # ---------------------------------------------------------
    # 3. Deploy mock tokens (18 decimals for simplicity)
    # ---------------------------------------------------------
    tx_hash = MockERC20.constructor("TokenA", "TKNA", 18).transact({"from": deployer})
    tokenA = w3.eth.wait_for_transaction_receipt(tx_hash).contractAddress
    tx_hash = MockERC20.constructor("TokenB", "TKNB", 18).transact({"from": deployer})
    tokenB = w3.eth.wait_for_transaction_receipt(tx_hash).contractAddress
    token0, token1 = sorted([tokenA, tokenB], key=lambda x: int(x, 16))
    print("token0, token1:", token0, token1)

    # ---------------------------------------------------------
    # 4. Deploy PolicyManager
    # ---------------------------------------------------------
    supported_ts = [10, 60, 200]
    tx_hash = PolicyManager.constructor(
        deployer,
        3000,  # default base fee ppm
        supported_ts,
        0,
        deployer,
        100,
        50000,
    ).transact({"from": deployer})
    policy_addr = w3.eth.wait_for_transaction_receipt(tx_hash).contractAddress
    policyManager = w3.eth.contract(address=policy_addr, abi=abi_policy)

    # ---------------------------------------------------------
    # 5. Deploy Oracle (hook placeholder = 0)
    # ---------------------------------------------------------
    tx_hash = Oracle.constructor(
        pool_manager_addr,
        policy_addr,
        Web3.to_checksum_address("0x" + "00" * 20),
        deployer,
    ).transact({"from": deployer})
    oracle_addr = w3.eth.wait_for_transaction_receipt(tx_hash).contractAddress
    oracle = w3.eth.contract(address=oracle_addr, abi=abi_oracle)

    # ---------------------------------------------------------
    # 6. Deploy LiquidityManager
    # ---------------------------------------------------------
    tx_hash = LiquidityManager.constructor(
        pool_manager_addr,
        Web3.to_checksum_address("0x" + "00" * 20),  # ExtendedPositionManager placeholder
        policy_addr,
        deployer,
    ).transact({"from": deployer})
    lm_addr = w3.eth.wait_for_transaction_receipt(tx_hash).contractAddress
    liquidityManager = w3.eth.contract(address=lm_addr, abi=abi_lm)

    # ---------------------------------------------------------
    # 7. Deploy DynamicFeeManager with temporary hook addr = deployer
    # ---------------------------------------------------------
    tx_hash = DynamicFeeManager.constructor(
        deployer,
        policy_addr,
        oracle_addr,
        deployer,  # temp authorized hook
    ).transact({"from": deployer})
    dfm_addr = w3.eth.wait_for_transaction_receipt(tx_hash).contractAddress
    dfm = w3.eth.contract(address=dfm_addr, abi=abi_dfm)

    # ---------------------------------------------------------
    # 8. Deploy/Create2 factory (if not cached)
    # ---------------------------------------------------------
    factory = compile_create2_factory(w3)

    # ---------------------------------------------------------
    # 9. Prepare Spot constructor args & mine hook address
    # ---------------------------------------------------------
    spot_args = encode(
        ["address", "address", "address", "address", "address", "address"],
        [pool_manager_addr, policy_addr, lm_addr, oracle_addr, dfm_addr, deployer],
    )
    creation_code = bytes.fromhex(byte_spot.replace('0x', '')) + spot_args

    salt, predicted_addr = find_salt_for_flags(factory.address, creation_code, REQUIRED_HOOK_FLAGS)
    print(f"Found salt {salt} – predicted Spot addr {predicted_addr}")

    # ---------------------------------------------------------
    # 10. Deploy Create2Factory (if not cached) and deploy Spot
    # ---------------------------------------------------------
    salt_bytes32 = salt.to_bytes(32, byteorder="big")
    tx_hash = factory.functions.deploy(creation_code, salt_bytes32).transact({"from": deployer, "gas": 30_000_000})
    w3.eth.wait_for_transaction_receipt(tx_hash)
    spot_addr = predicted_addr
    # Verify code was deployed
    if len(w3.eth.get_code(spot_addr)) == 0:
        raise RuntimeError("CREATE2 deployment failed")
    spotHook = w3.eth.contract(address=spot_addr, abi=abi_spot)
    print("Spot hook deployed at:", spot_addr)

    # Authorise hook in DFM & LM; wire oracle
    dfm.functions.setAuthorizedHook(spot_addr).transact({"from": deployer})
    liquidityManager.functions.setAuthorizedHookAddress(spot_addr).transact({"from": deployer})
    oracle.functions.setHookAddress(spot_addr).transact({"from": deployer})

    # ---------------------------------------------------------
    # 11. Build PoolKey & initialize pool
    # ---------------------------------------------------------
    FEE = 3000
    TICK_SPACING = 60
    pool_key = (
        token0,
        token1,
        FEE,
        TICK_SPACING,
        spot_addr,
    )
    init_price = 1.0  # start at price 1:1
    sqrt_price_x96 = int((math.sqrt(init_price)) * (1 << 96))
    poolManager.functions.initialize(pool_key, sqrt_price_x96).transact({"from": deployer})

    # ---------------------------------------------------------
    # 12. Deploy test routers
    # ---------------------------------------------------------
    swap_router_addr = w3.eth.wait_for_transaction_receipt(
        SwapRouterC.constructor(pool_manager_addr).transact({"from": deployer})
    ).contractAddress
    lp_router_addr = w3.eth.wait_for_transaction_receipt(
        LPRouterC.constructor(pool_manager_addr).transact({"from": deployer})
    ).contractAddress
    swapRouter = w3.eth.contract(address=swap_router_addr, abi=abi_swapT)
    lpRouter = w3.eth.contract(address=lp_router_addr, abi=abi_liqT)

    # ---------------------------------------------------------
    # 13. Mint tokens & provide initial full-range liquidity
    # ---------------------------------------------------------
    tokenA_c = w3.eth.contract(address=token0, abi=abi_token)
    tokenB_c = w3.eth.contract(address=token1, abi=abi_token)

    amount0 = 10 ** 21  # 1,000 TKNA
    amount1 = 10 ** 21  # 1,000 TKNB

    tokenA_c.functions.mint(lp_provider, amount0).transact({"from": deployer})
    tokenB_c.functions.mint(lp_provider, amount1).transact({"from": deployer})

    # approvals
    for t in (tokenA_c, tokenB_c):
        t.functions.approve(lp_router_addr, 2 ** 256 - 1).transact({"from": lp_provider})

    MIN_TICK = -887272
    MAX_TICK = 887272
    modify_params = (
        MIN_TICK,
        MAX_TICK,
        amount0,
        amount1,
        0,
        0,
        lp_provider,
    )
    lpRouter.functions.modifyLiquidity(pool_key, modify_params).transact({"from": lp_provider})
    print("Initial liquidity added.")

    # ---------------------------------------------------------
    # 14. Perform a single swap (move price by small amount)
    # ---------------------------------------------------------
    sqrt_limit = int((math.sqrt(1.05)) * (1 << 96))
    swap_params = (
        False,           # zeroForOne?
        10 ** 20,        # amountSpecified (large)
        sqrt_limit,
    )
    swapRouter.functions.swap(pool_key, swap_params).transact({"from": user, "gas": 1_000_000})
    print("Swap executed.")

    # ---------------------------------------------------------
    # 15. Query fee state for sanity
    # ---------------------------------------------------------
    pool_id = poolManager.functions.toId(pool_key).call()
    base_fee, surge_fee = dfm.functions.getFeeState(pool_id).call()
    print("BaseFee:", base_fee, "SurgeFee:", surge_fee)
    assert surge_fee == 0, "Surge fee should be 0 immediately after first small swap"
    print("Phase 1 simulation SUCCESS ✅")


if __name__ == "__main__":
    main()