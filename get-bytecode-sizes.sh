#!/bin/bash

# Clean and build the project
echo "Building contracts..."
forge clean
forge build --use solc:0.8.27

# Create a temporary file to store contract names
contract_files=$(find src -name "*.sol" | sort)

echo "Calculating bytecode sizes for all contracts..."
echo "Contract,Deployed Bytecode Size (bytes)"

# Loop through all contracts and get bytecode sizes
for file in $contract_files; do
    # Get the contract name from the file name
    contract_name=$(basename "$file" .sol)
    
    # Check if the file contains multiple contracts
    contracts=$(grep -E "^(contract|abstract contract|library|interface) " "$file" | awk '{print $2}' | sed 's/{//')
    
    for contract in $contracts; do
        # Skip interfaces as they don't have bytecode
        if grep -q "interface $contract" "$file"; then
            continue
        fi
        
        # Get the deployed bytecode
        bytecode=$(forge inspect --use solc:0.8.27 "$contract" deployedBytecode 2>/dev/null)
        
        # Check if bytecode retrieval was successful
        if [ $? -eq 0 ] && [ -n "$bytecode" ] && [ "$bytecode" != "null" ] && [ "$bytecode" != "{}" ]; then
            # Remove "0x" prefix and calculate length
            bytecode_length=$(($(echo "$bytecode" | sed 's/^0x//' | wc -c) / 2))
            
            if [ $bytecode_length -gt 0 ]; then
                echo "$contract,$bytecode_length"
            fi
        fi
    done
done | sort -t, -k2 -nr  # Sort by bytecode size descending 