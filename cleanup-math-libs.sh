#!/bin/bash
# File removal script for math consolidation

# Files targeted for removal
FILES_TO_REMOVE=(
  "src/libraries/LiquidityMath.sol"
  "src/libraries/Fees.sol"
  "src/libraries/PodsLibrary.sol"
  "src/libraries/FullRangeMathLib.sol"
)

# Check if files exist and remove them
for file in "${FILES_TO_REMOVE[@]}"; do
  if [ -f "$file" ]; then
    echo "Removing $file..."
    git rm "$file"
  else
    echo "File $file already removed"
  fi
done

# Update lcov.info to remove references to deleted files
if [ -f "lcov.info" ]; then
  echo "Updating coverage information..."
  for file in "${FILES_TO_REMOVE[@]}"; do
    sed -i "" "/SF:${file//\//\\/}/,/end_of_record/d" lcov.info
  fi
fi

# Check for any remaining imports of removed libraries
echo "Checking for any remaining imports..."
grep -r "import.*LiquidityMath" src/ || echo "No more LiquidityMath imports"
grep -r "import.*Fees" src/ || echo "No more Fees imports"
grep -r "import.*PodsLibrary" src/ || echo "No more PodsLibrary imports"
grep -r "import.*FullRangeMathLib" src/ || echo "No more FullRangeMathLib imports"

echo "Math library clean-up complete." 