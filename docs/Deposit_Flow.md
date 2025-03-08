Token Flows in FullRange Contract with Exact Addresses
The FullRange contract manages two distinct but related token flows: the ERC20 token liquidity and the ERC6909 position claims. Here's exactly how these work with specific addresses for each step:
Deposit Flow
ERC20 Liquidity Flow During Deposit:
User Approval:
User (ownerAddress) approves FullRange contract (address(this)) to spend their tokens
User also approves PoolManager (address(poolManager)) for direct transfers if required
Token Transfer:
When depositFullRange() is called, in unlockCallback():
For ERC20 tokens: callbackKey.currency0.take(callbackParams.ownerAddress, address(poolManager), callbackParams.amount0)
FROM: ownerAddress (the user)
TO: address(poolManager) (the Uniswap V4 PoolManager)
For native currency: poolManager.settle{value: callbackParams.amount0}()
FROM: address(this) (the FullRange contract that received ETH as msg.value)
TO: address(poolManager) (the Uniswap V4 PoolManager)
Liquidity Modification:
The contract calls poolManager.modifyLiquidity()
FROM: address(this) (the FullRange contract)
AFFECTING: The pool identified by poolId
Delta Settlement:
For negative deltas: poolManager.settle()
This just acknowledges the tokens already sent, no additional transfers
ERC6909 Claims Flow During Deposit:
Claims Minting:
poolManager.mint(callbackParams.ownerAddress, positionId, uint256(callbackParams.liquidityDelta))
FROM: address(0) (minted fresh)
TO: callbackParams.ownerAddress (the user who deposited)
ID: positionId (derived from the poolId using getFullRangePositionId(poolId))
Withdrawal Flow
ERC6909 Claims Flow During Withdrawal:
Share Burning:
poolManager.burn(callbackParams.ownerAddress, positionId, uint256(-callbackParams.liquidityDelta))
FROM: callbackParams.ownerAddress (the user)
TO: address(0) (burned)
ID: positionId (derived from the poolId using getFullRangePositionId(poolId))
ERC20 Liquidity Flow During Withdrawal:
Liquidity Removal:
The contract calls poolManager.modifyLiquidity() with negative delta
FROM: Pool reserves
AFFECTING: The pool identified by poolId
Token Transfer to User:
For positive deltas: callbackKey.currency0.take(address(poolManager), callbackParams.ownerAddress, uint256(uint128(modifyDelta.amount0())))
FROM: address(poolManager) (the Uniswap V4 PoolManager)
TO: callbackParams.ownerAddress (the user who initiated withdrawal)
Address Flow Summary Tables
Deposit Flow Addresses
| Step | Operation | From | To | Notes |
|------|-----------|------|----|----|
| 1 | User Approval (ERC20) | ownerAddress (user) | address(this) (FullRange) | Approval, not transfer |
| 2a | ERC20 Transfer | ownerAddress (user) | address(poolManager) | Via currency.take() |
| 2b | Native ETH Transfer | address(this) (FullRange) | address(poolManager) | Via settle{value:}() |
| 3 | Modify Liquidity | Pool reserves | Pool position | No address transfer |
| 4 | Mint ERC6909 Claims | address(0) (newly minted) | ownerAddress (user) | Via poolManager.mint() |
Withdrawal Flow Addresses
| Step | Operation | From | To | Notes |
|------|-----------|------|----|----|
| 1 | Burn ERC6909 Claims | ownerAddress (user) | address(0) (burned) | Via poolManager.burn() |
| 2 | Modify Liquidity | Pool position | Pool reserves | Negative liquidity delta |
| 3 | ERC20 Transfer Out | address(poolManager) | ownerAddress (user) | Via currency.take() |
Critical Address Rules
ERC20 Tokens Must Flow Through PoolManager:
Tokens must always go through the PoolManager, never directly to/from the FullRange contract
Exception: Native ETH is received by FullRange first, then forwarded to PoolManager
ERC6909 Position Tokens Are Direct:
Position tokens are minted directly to the user's address (ownerAddress)
Position tokens are burned directly from the user's address (ownerAddress)
Position ID Consistency:
The same positionId derived from getFullRangePositionId(poolId) must be used for both minting and burning
This ensures claims are properly tracked for the specific pool
This detailed address flow ensures that tokens and claims move correctly between the relevant contracts and users, maintaining proper accounting in the system.