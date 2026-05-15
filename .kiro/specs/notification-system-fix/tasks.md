# Implementation Plan

- [x] 1. Write bug condition exploration test
  - **Property 1: Bug Condition** - Leader Exclusion and Silent Failure
  - **CRITICAL**: This test MUST FAIL on unfixed code - failure confirms the bug exists
  - **DO NOT attempt to fix the test or the code when it fails**
  - **NOTE**: This test encodes the expected behavior - it will validate the fix when it passes after implementation
  - **GOAL**: Surface counterexamples that demonstrate both bugs exist
  - **Scoped PBT Approach**: Scope the property to two concrete failing scenarios:
    1. Leader with assigned tasks when `send_leads=1` and `send_assignees=1` — verify leader UID appears in `collect_assignee_uids` output
    2. Script execution with pending tasks but 0 successful sends — verify `[CRITICAL]` log is emitted
  - Create a test script (`tests/test_bug_condition.sh`) that sources `remind.sh` functions and mocks Discord API
  - Test Case A: Configure a leader (e.g., "dmvelezp@sena.edu.co") who also has assigned tasks. Call `collect_assignee_uids` with `exclude_lead_uids=1` (current behavior). Assert leader UID IS in the output (will FAIL — confirms Bug 1)
  - Test Case B: Configure a user whose email is NOT in `DISCORD_USER_MAP_JSON`. Run the notification flow. Assert script emits `[CRITICAL]` log when `sent=0` and tasks exist (will FAIL — confirms Bug 2)
  - Run test on UNFIXED code
  - **EXPECTED OUTCOME**: Test FAILS (this is correct - it proves the bugs exist)
  - Document counterexamples found:
    - Bug 1: Leader UID filtered out by `is_lead_uid` check in `collect_assignee_uids` when `exclude_lead_uids=1`
    - Bug 2: Script exits with code 0 and informational log only when `sent=0` with pending tasks
  - Mark task complete when test is written, run, and failure is documented
  - _Requirements: 1.1, 1.2, 1.6_

- [x] 2. Write preservation property tests (BEFORE implementing fix)
  - **Property 2: Preservation** - Non-Leader Assignees and Exclusive Modes
  - **IMPORTANT**: Follow observation-first methodology
  - **GOAL**: Capture baseline behavior of unfixed code for non-buggy inputs to prevent regressions
  - Create test script (`tests/test_preservation.sh`) that sources `remind.sh` functions and mocks Discord API
  - Observe on UNFIXED code:
    - `collect_assignee_uids` with `exclude_lead_uids=0` includes non-leader assignees correctly
    - With `TAIGA_NOTIFY_ONLY_LEAD=true`, only leader reports are sent (no assignee DMs)
    - With `TAIGA_NOTIFY_EXCLUDE_LEAD=true`, only assignee DMs are sent (no leader reports)
    - When no tasks are pending (empty `combined`), script exits 0 with no sends
    - Deduplication: second run same day skips already-sent users
  - Write property-based tests capturing observed behavior:
    - Property: For all non-leader assignees with pending tasks, `collect_assignee_uids` with `exclude_lead_uids=0` returns their UID
    - Property: For all executions with `TAIGA_NOTIFY_ONLY_LEAD=true`, `send_assignees=0` and no assignee DMs are attempted
    - Property: For all executions with `TAIGA_NOTIFY_EXCLUDE_LEAD=true`, `send_leads=0` and no leader reports are attempted
    - Property: For all executions with empty `combined`, exit code is 0 and `sent=0`
    - Property: For all users already marked in state file, `already_sent_today` returns true and DM is skipped
  - Run tests on UNFIXED code
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8_

- [x] 3. Fix for leader exclusion and silent failure bugs

  - [x] 3.1 Remove leader exclusion logic from `main()` and `collect_assignee_uids()`
    - Remove the line: `[[ "$send_leads" -eq 1 && "$send_assignees" -eq 1 ]] && exclude_lead_from_assignee_list=1`
    - Remove the `exclude_lead_from_assignee_list` variable declaration (set it to always `0` or remove entirely)
    - In `collect_assignee_uids`, remove the conditional block that filters leaders:
      ```
      if [[ "$exclude_lead_uids" -eq 1 ]] && is_lead_uid "$aid" "$lead_json"; then
        continue
      fi
      ```
    - Update the call to `collect_assignee_uids` to pass `0` or remove the third parameter
    - Leaders with assigned pending tasks will now appear in both the leader report loop AND the assignee DM loop
    - _Bug_Condition: isBugCondition(input) where send_leads=1 AND send_assignees=1 AND user_is_leader=true AND user_has_pending_tasks=true_
    - _Expected_Behavior: leader_uid IN collect_assignee_uids_fixed(combined, lead_ids, 0) — leaders receive BOTH messages_
    - _Preservation: Non-leader assignees unaffected; ONLY_LEAD and EXCLUDE_LEAD modes unchanged_
    - _Requirements: 2.1, 2.2_

  - [x] 3.2 Add failure counter and enhanced summary logging
    - Declare `failed=0` alongside existing counters (`sent`, `skip`, `miss`)
    - In the leader DM loop, add `else failed=$((failed+1))` when `send_dm` fails
    - In the assignee DM loop, add `else failed=$((failed+1))` when `send_dm` fails
    - Update the final log line to include `fallidos=$failed`:
      ```
      log "DM enviados=$sent | fallidos=$failed | dm_lideres=$sent_leads | dm_responsables=$sent_assignees | ya_enviados_hoy=$skip | lideres_mapeados=$leaders_count | sin_mapeo_responsable=$miss"
      ```
    - _Bug_Condition: isBugCondition(input) where tasks_to_notify > 0 AND successful_sends == 0 AND NOT critical_error_logged()_
    - _Expected_Behavior: result.summary CONTAINS "fallidos" with accurate count_
    - _Preservation: Log format extended but existing fields unchanged_
    - _Requirements: 2.3, 2.4_

  - [x] 3.3 Add critical failure detection after summary
    - After the final log line, add logic to detect total failure:
      ```bash
      local total_to_notify
      total_to_notify="$(echo "$combined" | jq 'length')"
      if [[ "$total_to_notify" -gt 0 && "$sent" -eq 0 && "$skip" -eq 0 ]]; then
        log "[CRITICAL] Hay $total_to_notify tareas pendientes pero 0 notificaciones enviadas. Fallos=$failed, Sin_mapeo=$miss"
        exit 2
      fi
      ```
    - Use `exit 2` to distinguish from `exit 1` (config error) and `exit 0` (success)
    - Only trigger when `skip=0` (if all were deduped, that's not a failure)
    - _Bug_Condition: isBugCondition(input) where tasks_to_notify > 0 AND successful_sends == 0 AND NOT critical_error_logged()_
    - _Expected_Behavior: result.logs CONTAINS "[CRITICAL]" AND result.exit_code == 2_
    - _Preservation: Normal executions with successful sends unaffected; no-task executions unaffected_
    - _Requirements: 2.5, 2.6_

  - [x] 3.4 Verify bug condition exploration test now passes
    - **Property 1: Expected Behavior** - Leader Exclusion and Silent Failure
    - **IMPORTANT**: Re-run the SAME test from task 1 - do NOT write a new test
    - The test from task 1 encodes the expected behavior
    - When this test passes, it confirms the expected behavior is satisfied:
      - Leader UID now appears in `collect_assignee_uids` output (Bug 1 fixed)
      - `[CRITICAL]` log is emitted when `sent=0` with pending tasks (Bug 2 fixed)
    - Run bug condition exploration test from step 1
    - **EXPECTED OUTCOME**: Test PASSES (confirms bugs are fixed)
    - _Requirements: 2.1, 2.2, 2.6_

  - [x] 3.5 Verify preservation tests still pass
    - **Property 2: Preservation** - Non-Leader Assignees and Exclusive Modes
    - **IMPORTANT**: Re-run the SAME tests from task 2 - do NOT write new tests
    - Run preservation property tests from step 2
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Confirm all preservation tests still pass after fix:
      - Non-leader assignees still receive DMs correctly
      - ONLY_LEAD mode still works as before
      - EXCLUDE_LEAD mode still works as before
      - Empty task scenarios still exit cleanly
      - Deduplication still functions correctly

- [x] 4. Checkpoint - Ensure all tests pass
  - Run full test suite (bug condition + preservation tests)
  - Verify exit codes: all tests pass with exit 0
  - Verify no regressions in existing behavior
  - Ensure all tests pass, ask the user if questions arise
