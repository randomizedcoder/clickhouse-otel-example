# Test harness for verification scripts
{ pkgs, shellLib }:
let
  inherit (shellLib) commonFunctions mkVerifyScript;
in
{
  test-verify-scripts = mkVerifyScript {
    name = "test-verify-scripts";
    text = ''
      print_header "Verification Script Test Suite"

      TESTS_PASSED=0
      TESTS_FAILED=0
      TOTAL_TESTS=6

      run_test() {
        local test_num="$1"
        local name="$2"
        local break_cmd="$3"
        local verify_cmd="$4"
        local fix_cmd="$5"

        echo ""
        echo -e "''${BLUE}[TEST $test_num/$TOTAL_TESTS] Testing $name failure detection''${NC}"
        echo ""

        # Inject failure
        print_info "Injecting failure..."
        if ! nix run ".#$break_cmd" 2>&1; then
          print_fail "Failed to inject failure"
          TESTS_FAILED=$((TESTS_FAILED + 1))
          return
        fi

        # Wait a moment for the failure to take effect
        sleep 5

        # Run verify script, should fail
        print_info "Running $verify_cmd (expecting failure)..."
        if nix run ".#$verify_cmd" 2>&1; then
          print_fail "Verify script should have failed but passed"
          # Restore before continuing
          nix run ".#$fix_cmd" 2>&1 || true
          TESTS_FAILED=$((TESTS_FAILED + 1))
          return
        else
          print_pass "Verify script correctly detected failure"
        fi

        # Restore
        print_info "Restoring..."
        if ! nix run ".#$fix_cmd" 2>&1; then
          print_fail "Failed to restore"
          TESTS_FAILED=$((TESTS_FAILED + 1))
          return
        fi

        # Wait for restoration
        sleep 10

        # Run verify script again, should pass
        print_info "Running $verify_cmd (expecting success)..."
        if nix run ".#$verify_cmd" 2>&1; then
          print_pass "Verify script correctly detected recovery"
          print_pass "TEST $test_num PASSED"
          TESTS_PASSED=$((TESTS_PASSED + 1))
        else
          print_fail "Verify script should have passed after fix"
          TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
      }

      # Ensure pipeline is healthy before starting tests
      echo ""
      print_info "Ensuring pipeline is healthy before tests..."
      echo ""

      # Run all tests
      run_test 1 "verify-loggen" "break-loggen" "verify-loggen" "fix-loggen"
      run_test 2 "verify-fluentbit" "break-fluentbit" "verify-fluentbit" "fix-fluentbit"
      run_test 3 "verify-fluentbit-output" "break-fluentbit-output" "verify-fluentbit-output" "fix-fluentbit-output"
      run_test 4 "verify-clickhouse" "break-clickhouse" "verify-clickhouse" "fix-clickhouse"
      run_test 5 "verify-clickhouse-table" "break-clickhouse-table" "verify-clickhouse" "fix-clickhouse-table"
      run_test 6 "verify-hyperdx" "break-hyperdx" "verify-hyperdx" "fix-hyperdx"

      # Summary
      print_header "Test Suite Summary"
      echo "Tests Passed: $TESTS_PASSED/$TOTAL_TESTS"
      echo "Tests Failed: $TESTS_FAILED/$TOTAL_TESTS"

      if [ "$TESTS_FAILED" -eq 0 ]; then
        echo ""
        echo -e "''${GREEN}All verification scripts correctly detect failures!''${NC}"
        echo ""
      else
        echo ""
        echo -e "''${RED}Some tests failed - check output above''${NC}"
        echo ""
        exit 1
      fi
    '';
  };
}
