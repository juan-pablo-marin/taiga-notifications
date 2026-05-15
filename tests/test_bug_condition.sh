#!/usr/bin/env bash
# =============================================================================
# Bug Condition Exploration Test
# =============================================================================
# Property 1: Bug Condition — Leader Exclusion and Silent Failure
#
# **Validates: Requirements 1.1, 1.2, 1.6**
#
# This test MUST FAIL on unfixed code — failure confirms the bugs exist.
# DO NOT attempt to fix the test or the code when it fails.
#
# Test Case A: Leader with assigned tasks when send_leads=1 and send_assignees=1
#   — verify leader UID appears in collect_assignee_uids output
#
# Test Case B: Script execution with pending tasks but 0 successful sends
#   — verify [CRITICAL] log is emitted
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REMIND_SH="$PROJECT_DIR/scripts/remind.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: $msg"
    return 0
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: $msg"
    echo "  Expected to find: '$needle'"
    echo "  In output: '$(echo "$haystack" | head -c 500)'"
    return 1
  fi
}

echo "=============================================="
echo "Bug Condition Exploration Test"
echo "=============================================="
echo ""

# =============================================================================
# TEST CASE A: Leader Exclusion Bug
# =============================================================================
# Configure a leader (dmvelezp@sena.edu.co) who also has assigned tasks.
# Call collect_assignee_uids with exclude_lead_uids=1 (current behavior).
# Assert leader UID IS in the output.
# EXPECTED: FAIL — confirms Bug 1 (leader is filtered out)
# =============================================================================

echo "----------------------------------------------"
echo "TEST CASE A: Leader Exclusion Bug"
echo "----------------------------------------------"

LEADER_EMAIL="dmvelezp@sena.edu.co"
LEADER_UID="123456789012345678"

echo "Scenario: Leader '$LEADER_EMAIL' (UID=$LEADER_UID) has assigned tasks."
echo "  send_leads=1, send_assignees=1 -> exclude_lead_uids=1"
echo "  Expected: Leader UID should be in collect_assignee_uids output"
echo ""

# We extract the relevant functions from remind.sh and test them directly
# This avoids sourcing the whole script which triggers main()
CASE_A_OUTPUT="$(bash -c '
set -uo pipefail

# Environment setup
export DISCORD_USER_MAP_JSON="{\"dmvelezp@sena.edu.co\": \"123456789012345678\"}"
export DISCORD_LEAD_EMAILS="dmvelezp@sena.edu.co"

# Extract functions from remind.sh (everything except the main call at the end)
eval "$(sed -n "/^normalize_email/,/^main \"\\\$@\"/{ /^main \"\\\$@\"/d; p; }" "'"$REMIND_SH"'")"

# Also need the log function
log() { echo "[taiga-remind] $*" >&2; }

# Build lead IDs
lead_ids=$(list_lead_ids)
echo "LEAD_IDS=$lead_ids"

# Build combined tasks JSON with leader as assignee
combined='"'"'[
  {
    "id": 1,
    "ref": 100,
    "subject": "Test task assigned to leader",
    "due_date": "2026-01-15",
    "entity_type": "task",
    "assigned_to_extra_info": {
      "email": "dmvelezp@sena.edu.co",
      "username": "dmvelezp",
      "full_name_display": "Daniel Velez"
    }
  }
]'"'"'

# Call collect_assignee_uids with exclude_lead_uids=1 (the buggy path)
result=$(collect_assignee_uids "$combined" "$lead_ids" 1)
echo "ASSIGNEE_UIDS=$result"
' 2>&1)"

echo "Test Case A output:"
echo "$CASE_A_OUTPUT"
echo ""

# Check if leader UID appears in the output
assert_contains "$CASE_A_OUTPUT" "ASSIGNEE_UIDS=$LEADER_UID" \
  "Leader UID ($LEADER_UID) should appear in collect_assignee_uids output when exclude_lead_uids=1" || true

echo ""

# =============================================================================
# TEST CASE B: Silent Failure Bug
# =============================================================================
# Configure a scenario where there are pending tasks but 0 successful sends.
# Run the notification flow. Assert script emits [CRITICAL] log.
# EXPECTED: FAIL — confirms Bug 2 (no [CRITICAL] log emitted)
# =============================================================================

echo "----------------------------------------------"
echo "TEST CASE B: Silent Failure Bug"
echo "----------------------------------------------"
echo "Scenario: Pending tasks exist, all assignees unmapped, sent=0"
echo "  Expected: Script emits [CRITICAL] log when sent=0 with pending tasks"
echo ""

# Create a mock curl that simulates Taiga returning tasks but Discord failing
MOCK_DIR="/tmp/test_bug_condition_mocks"
mkdir -p "$MOCK_DIR"

cat > "$MOCK_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
# Mock curl for testing
args="$*"

# Parse -o flag for output file
out_file=""
prev=""
for arg in $args; do
  if [[ "$prev" == "-o" ]]; then
    out_file="$arg"
    break
  fi
  prev="$arg"
done

if echo "$args" | grep -q "api/v1/tasks"; then
  # Return a task with an unmapped assignee
  cat <<EOF
[
  {
    "id": 391,
    "ref": 391,
    "subject": "Tarea de Fredy vencida",
    "due_date": "2025-01-10T00:00:00Z",
    "assigned_to_extra_info": {
      "email": "fredy_unmapped@sena.edu.co",
      "username": "fredy",
      "full_name_display": "Fredy Unmapped"
    }
  }
]
EOF
elif echo "$args" | grep -q "api/v1/userstories"; then
  echo '[]'
elif echo "$args" | grep -q "discord.com"; then
  # Discord API - simulate failure
  if [[ -n "$out_file" ]]; then
    echo '{"message":"Unauthorized","code":401}' > "$out_file"
  fi
  # Return HTTP 401 status code (curl -w "%{http_code}" format)
  echo "401"
else
  echo '{}'
fi
MOCKCURL
chmod +x "$MOCK_DIR/curl"

# Create a temporary state file location
STATE_FILE="/tmp/test_bug_condition_state_b.json"
rm -f "$STATE_FILE"

# Run the full script with mocked curl
# The script should detect sent=0 with pending tasks and emit [CRITICAL]
CASE_B_OUTPUT="$(PATH="$MOCK_DIR:$PATH" bash -c '
export TAIGA_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_ID="1"
export DISCORD_BOT_TOKEN="fake-bot-token"
export DISCORD_USER_MAP_JSON="{\"leader@example.com\": \"999999999999999999\"}"
export DISCORD_LEAD_EMAIL="leader@example.com"
export DISCORD_LEAD_EMAILS="leader@example.com"
export TAIGA_AUTH_TOKEN="fake-auth-token"
export TAIGA_NOTIFY_STATE_FILE="/tmp/test_bug_condition_state_b.json"
export TAIGA_NOTIFY_ASSIGNEE=""
export TAIGA_NOTIFY_ONLY_LEAD="false"
export TAIGA_NOTIFY_EXCLUDE_LEAD="false"
export TAIGA_SSL_VERIFY="0"
export TAIGA_WEB_UI_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_SLUG="test-project"
export TZ="UTC"

source "'"$REMIND_SH"'"
' 2>&1)" || true
CASE_B_EXIT=$?

echo "Test Case B output:"
echo "$CASE_B_OUTPUT"
echo ""
echo "Test Case B exit code: $CASE_B_EXIT"
echo ""

# Assert: The output should contain [CRITICAL] when sent=0 and tasks exist
assert_contains "$CASE_B_OUTPUT" "[CRITICAL]" \
  "Script should emit [CRITICAL] log when sent=0 with pending tasks" || true

echo ""

# =============================================================================
# Summary
# =============================================================================

echo "=============================================="
echo "SUMMARY"
echo "=============================================="
echo "Tests run:    $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${YELLOW}NOTE: Test failures are EXPECTED on unfixed code.${NC}"
  echo "Counterexamples found:"
  echo "  Bug 1: Leader UID filtered out by is_lead_uid check in collect_assignee_uids"
  echo "         when exclude_lead_uids=1. The leader (dmvelezp@sena.edu.co, UID=$LEADER_UID)"
  echo "         has assigned tasks but is excluded from the assignee notification list."
  echo "  Bug 2: Script exits with code 0 and informational log only when sent=0"
  echo "         with pending tasks. No [CRITICAL] log is emitted to alert administrators."
  echo ""
  exit 1
else
  echo -e "${GREEN}All tests passed - bugs are fixed!${NC}"
  exit 0
fi
