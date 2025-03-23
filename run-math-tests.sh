#!/bin/bash
# Script to run MathUtils tests with gas reporting

# Set environment variables for better debugging
export FOUNDRY_PROFILE=ci
export FOUNDRY_VERBOSITY=1

# Clean any previous test artifacts
echo "Cleaning previous test artifacts..."
forge clean

# Run the tests with gas reporting
echo "Running MathUtils tests with gas reporting..."
forge test --match-path "test/MathUtilsTest.t.sol" --gas-report

# Generate gas report for specific functions
echo "Generating detailed gas report..."
forge test --match-path "test/MathUtilsTest.t.sol" --gas-report --match-test "testBenchmark" -vv

# Generate coverage report
echo "Generating test coverage report..."
forge coverage --match-path "test/MathUtilsTest.t.sol" --report lcov

# Execute lcov to generate HTML report if installed
if command -v lcov >/dev/null 2>&1; then
  echo "Generating HTML coverage report..."
  lcov --remove lcov.info "test/*" --output-file lcov.info
  genhtml lcov.info --output-directory coverage-report
  echo "HTML coverage report generated in coverage-report directory"
fi

echo "Test execution complete!" 