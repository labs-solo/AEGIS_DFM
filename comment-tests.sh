#!/bin/bash

# Script to comment out all the test files in the old-tests directory

# Find all .t.sol files in old-tests directory and its subdirectories
TEST_FILES=$(find test/old-tests -type f -name "*.t.sol" -o -name "*.t.sol.bak")

for FILE in $TEST_FILES; do
  echo "Commenting out $FILE"
  
  # Create a new file with comments
  echo "// SPDX-License-Identifier: BUSL-1.1" > "${FILE}.new"
  echo "pragma solidity 0.8.26;" >> "${FILE}.new"
  echo "" >> "${FILE}.new"
  echo "/*" >> "${FILE}.new"
  echo " * This test file has been moved to old-tests and commented out." >> "${FILE}.new"
  echo " * It is kept for reference but is no longer used in the project." >> "${FILE}.new"
  echo " * The new testing approach uses LocalUniswapV4TestBase.t.sol for local deployments." >> "${FILE}.new"
  echo " */" >> "${FILE}.new"
  echo "" >> "${FILE}.new"
  echo "/*" >> "${FILE}.new"
  
  # Add the original content wrapped in block comments
  cat "$FILE" | grep -v "SPDX-License-Identifier" | grep -v "pragma solidity" >> "${FILE}.new"
  
  echo "*/" >> "${FILE}.new"
  
  # Replace the original with the commented version
  mv "${FILE}.new" "$FILE"
done

echo "All test files have been commented out." 