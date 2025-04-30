#!/bin/bash

# Find all Solidity files and update Solmate imports in both project and v4-core
find src test node_modules/v4-core/src -type f -name "*.sol" | while read -r file; do
    echo "Processing $file..."
    
    # Update ERC20 imports
    sed -i '' 's|"solmate/src/tokens/ERC20.sol"|"solmate/tokens/ERC20.sol"|g' "$file"
    
    # Update SafeTransferLib imports
    sed -i '' 's|"solmate/src/utils/SafeTransferLib.sol"|"solmate/utils/SafeTransferLib.sol"|g' "$file"
    
    # Update FixedPointMathLib imports
    sed -i '' 's|"solmate/src/utils/FixedPointMathLib.sol"|"solmate/utils/FixedPointMathLib.sol"|g' "$file"

    # Update Owned imports
    sed -i '' 's|"solmate/src/auth/Owned.sol"|"solmate/auth/Owned.sol"|g' "$file"

    # Generic catch-all for any remaining solmate/src/ imports
    sed -i '' 's|"solmate/src/|"solmate/|g' "$file"
done

echo "All Solmate imports have been updated." 