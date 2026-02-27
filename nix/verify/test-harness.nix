# Test harness for verification scripts
{ pkgs, shellLib }:
let
  inherit (shellLib) mkVerifyScript;

  # Define all test cases in one place - auto-calculates total
  testCases = [
    { name = "verify-loggen"; breakCmd = "break-loggen"; verifyCmd = "verify-loggen"; fixCmd = "fix-loggen"; }
    { name = "verify-fluentbit"; breakCmd = "break-fluentbit"; verifyCmd = "verify-fluentbit"; fixCmd = "fix-fluentbit"; }
    { name = "verify-fluentbit-output"; breakCmd = "break-fluentbit-output"; verifyCmd = "verify-fluentbit-output"; fixCmd = "fix-fluentbit-output"; }
    { name = "verify-clickhouse"; breakCmd = "break-clickhouse"; verifyCmd = "verify-clickhouse"; fixCmd = "fix-clickhouse"; }
    { name = "verify-clickhouse-table"; breakCmd = "break-clickhouse-table"; verifyCmd = "verify-clickhouse"; fixCmd = "fix-clickhouse-table"; }
    { name = "verify-hyperdx"; breakCmd = "break-hyperdx"; verifyCmd = "verify-hyperdx"; fixCmd = "fix-hyperdx"; }
  ];

  totalTests = builtins.length testCases;

  # Generate the test array for bash
  testArrayEntries = builtins.concatStringsSep "\n" (
    builtins.map (tc: ''TESTS+=("${tc.name}|${tc.breakCmd}|${tc.verifyCmd}|${tc.fixCmd}")'') testCases
  );
in
{
  test-verify-scripts = mkVerifyScript {
    name = "test-verify-scripts";
    text = ''
      print_header "Verification Script Test Suite"

      TESTS_PASSED=0
      TESTS_FAILED=0
      TOTAL_TESTS=${toString totalTests}

      # Test definitions: name|break_cmd|verify_cmd|fix_cmd
      declare -a TESTS
      ${testArrayEntries}

      run_test() {
        local test_num="$1"
        local test_def="$2"

        # Parse test definition
        IFS='|' read -r name break_cmd verify_cmd fix_cmd <<< "$test_def"

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
      test_num=1
      for test_def in "''${TESTS[@]}"; do
        run_test "$test_num" "$test_def"
        test_num=$((test_num + 1))
      done

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
