#!/bin/bash
set -e  # Exit on any error

# Script to run MathUtils tests with gas reporting

echo "====================================================="
echo "Running MathUtils comprehensive test suite"
echo "====================================================="

# Set environment variables for better debugging
export FOUNDRY_PROFILE=ci
export FOUNDRY_VERBOSITY=1

# Clean any previous test artifacts
echo "Cleaning previous test artifacts..."
forge clean || { echo "Failed to clean artifacts"; exit 1; }

# Create a results directory for test output
RESULTS_DIR="math-test-results"
mkdir -p $RESULTS_DIR

# Trap to handle cleanup in case of failure
trap "echo 'Test execution failed. Check logs in $RESULTS_DIR.'" ERR

# Run the tests with gas reporting
echo "Running MathUtils tests with gas reporting..."
forge test --match-path "test/MathUtilsTest.t.sol" --gas-report | tee "$RESULTS_DIR/test-basic-output.log" || { echo "Basic tests failed"; exit 1; }

# Generate gas report for specific functions
echo "Generating detailed gas report..."
forge test --match-path "test/MathUtilsTest.t.sol" --gas-report --match-test "testBenchmark" -vv | tee "$RESULTS_DIR/gas-benchmark.log" || { echo "Gas benchmarking failed"; exit 1; }

# Generate coverage report
echo "Generating test coverage report..."
forge coverage --match-path "test/MathUtilsTest.t.sol" --report lcov | tee "$RESULTS_DIR/coverage-output.log" || { echo "Coverage analysis failed"; exit 1; }

# Execute lcov to generate HTML report if installed
if command -v lcov >/dev/null 2>&1; then
  echo "Generating HTML coverage report..."
  lcov --remove lcov.info "test/*" --output-file lcov.info
  genhtml lcov.info --output-directory "$RESULTS_DIR/coverage-report"
  echo "HTML coverage report generated in $RESULTS_DIR/coverage-report directory"
else
  echo "lcov not installed - skipping HTML report generation"
  echo "To install lcov: brew install lcov (Mac) or apt-get install lcov (Ubuntu)"
fi

echo "====================================================="
echo "Test execution complete! Results saved in $RESULTS_DIR"
echo "=====================================================" 