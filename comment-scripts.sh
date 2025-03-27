#!/bin/bash

# Script to comment out all the old script files except our new local deployment script

# Files to comment out
SCRIPT_FILES=(
  "script/mocks/MockER20.s.sol"
  "script/01a_CreatePoolOnly.s.sol"
  "script/03_Swap.s.sol"
  "script/01_CreatePoolAndMintLiquidity.s.sol"
  "script/02_AddLiquidity.s.sol"
  "script/base/Config.sol"
)

for FILE in "${SCRIPT_FILES[@]}"; do
  echo "Commenting out $FILE"
  
  # Create a new file with comments
  echo "// SPDX-License-Identifier: BUSL-1.1" > "${FILE}.new"
  echo "pragma solidity ^0.8.19;" >> "${FILE}.new"
  echo "" >> "${FILE}.new"
  echo "/*" >> "${FILE}.new"
  echo " * This file has been commented out as part of migrating to local Uniswap V4 testing." >> "${FILE}.new"
  echo " * It is kept for reference but is no longer used in the project." >> "${FILE}.new"
  echo " */" >> "${FILE}.new"
  echo "" >> "${FILE}.new"
  echo "/*" >> "${FILE}.new"
  
  # Add the original content wrapped in block comments
  cat "$FILE" | grep -v "SPDX-License-Identifier" | grep -v "pragma solidity" >> "${FILE}.new"
  
  echo "*/" >> "${FILE}.new"
  
  # Replace the original with the commented version
  mv "${FILE}.new" "$FILE"
done

echo "All script files have been commented out." 