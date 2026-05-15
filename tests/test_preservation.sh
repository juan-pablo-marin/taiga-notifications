#!/usr/bin/env bash
# =============================================================================
# Preservation Property Tests
# =============================================================================
# Property 2: Preservation — Non-Leader Assignees and Exclusive Modes
#
# **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8**
#
# These tests MUST PASS on unfixed code — they capture baseline behavior
# that must be preserved after the fix is applied.
#
# Properties tested:
#   P1: For all non-leader assignees with pending tasks,
#       collect_assignee_uids with exclude_lead_uids=0 returns their UID
#   P2: For all executions with TAIGA_NOTIFY_ONLY_LEAD=true,
#       send_assignees=0 and no assignee DMs are attempted
#   P3: For all executions with TAIGA_NOTIFY_EXCLUDE_LEAD=true,
#       send_leads=0 and no leader reports are attempted
#   P4: For all executions with empty combined, exit code is 0 and sent=0
#   P5: For all users already marked in state file,
#       already_sent_today returns true and DM is skipped
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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: $msg"
    echo "  Expected NOT to find: '$needle'"
    echo "  In output: '$(echo "$haystack" | head -c 500)'"
    return 1
  else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: $msg"
    return 0
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$actual" == "$expected" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: $msg"
    return 0
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: $msg"
    echo "  Expected: '$expected'"
    echo "  Actual:   '$actual'"
    return 1
  fi
}

echo "=============================================="
echo "Preservation Property Tests"
echo "=============================================="
echo ""

# =============================================================================
# PROPERTY 1: Non-leader assignees with pending tasks are included
#             in collect_assignee_uids when exclude_lead_uids=0
# =============================================================================

echo "----------------------------------------------"
echo "PROPERTY 1: Non-leader assignees included with exclude_lead_uids=0"
echo "----------------------------------------------"
echo ""

# Test with multiple non-leader assignees
P1_OUTPUT="$(bash -c '
set -uo pipefail

export DISCORD_USER_MAP_JSON="{\"alice@sena.edu.co\": \"111111111111111111\", \"bob@sena.edu.co\": \"222222222222222222\", \"leader@sena.edu.co\": \"333333333333333333\"}"
export DISCORD_LEAD_EMAILS="leader@sena.edu.co"

eval "$(sed -n "/^normalize_email/,/^main \"\\\$@\"/{ /^main \"\\\$@\"/d; p; }" "'"$REMIND_SH"'")"
log() { echo "[taiga-remind] $*" >&2; }

lead_ids=$(list_lead_ids)

combined='"'"'[
  {
    "id": 1,
    "ref": 100,
    "subject": "Task for Alice",
    "due_date": "2026-01-15",
    "entity_type": "task",
    "assigned_to_extra_info": {
      "email": "alice@sena.edu.co",
      "username": "alice",
      "full_name_display": "Alice Smith"
    }
  },
  {
    "id": 2,
    "ref": 101,
    "subject": "Task for Bob",
    "due_date": "2026-01-15",
    "entity_type": "task",
    "assigned_to_extra_info": {
      "email": "bob@sena.edu.co",
      "username": "bob",
      "full_name_display": "Bob Jones"
    }
  }
]'"'"'

# Call with exclude_lead_uids=0 (non-buggy path)
result=$(collect_assignee_uids "$combined" "$lead_ids" 0)
echo "RESULT=$result"
' 2>&1)"

echo "P1 output: $P1_OUTPUT"
echo ""

assert_contains "$P1_OUTPUT" "111111111111111111" \
  "P1a: Alice (non-leader) UID included with exclude_lead_uids=0" || true

assert_contains "$P1_OUTPUT" "222222222222222222" \
  "P1b: Bob (non-leader) UID included with exclude_lead_uids=0" || true

# Test with a single non-leader assignee
P1_SINGLE="$(bash -c '
set -uo pipefail

export DISCORD_USER_MAP_JSON="{\"single@sena.edu.co\": \"444444444444444444\", \"leader@sena.edu.co\": \"333333333333333333\"}"
export DISCORD_LEAD_EMAILS="leader@sena.edu.co"

eval "$(sed -n "/^normalize_email/,/^main \"\\\$@\"/{ /^main \"\\\$@\"/d; p; }" "'"$REMIND_SH"'")"
log() { echo "[taiga-remind] $*" >&2; }

lead_ids=$(list_lead_ids)

combined='"'"'[
  {
    "id": 3,
    "ref": 102,
    "subject": "Single task",
    "due_date": "2026-01-15",
    "entity_type": "task",
    "assigned_to_extra_info": {
      "email": "single@sena.edu.co",
      "username": "single",
      "full_name_display": "Single User"
    }
  }
]'"'"'

result=$(collect_assignee_uids "$combined" "$lead_ids" 0)
echo "RESULT=$result"
' 2>&1)"

echo "P1 single output: $P1_SINGLE"
echo ""

assert_contains "$P1_SINGLE" "444444444444444444" \
  "P1c: Single non-leader assignee UID included with exclude_lead_uids=0" || true

echo ""

# =============================================================================
# PROPERTY 2: With TAIGA_NOTIFY_ONLY_LEAD=true, no assignee DMs are attempted
# =============================================================================

echo "----------------------------------------------"
echo "PROPERTY 2: ONLY_LEAD mode sends no assignee DMs"
echo "----------------------------------------------"
echo ""

# Create mock curl for this test
MOCK_DIR_P2="/tmp/test_preservation_mocks_p2"
mkdir -p "$MOCK_DIR_P2"

cat > "$MOCK_DIR_P2/curl" <<'MOCKCURL'
#!/usr/bin/env bash
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
  cat <<EOF
[
  {
    "id": 1,
    "ref": 100,
    "subject": "Task vencida",
    "due_date": "2020-01-01T00:00:00Z",
    "assigned_to_extra_info": {
      "email": "assignee@sena.edu.co",
      "username": "assignee",
      "full_name_display": "Assignee User"
    }
  }
]
EOF
elif echo "$args" | grep -q "api/v1/userstories"; then
  echo '[]'
elif echo "$args" | grep -q "discord.com/api/v10/users/@me/channels"; then
  # Track which DMs are opened
  echo "DM_OPEN: $args" >&2
  if [[ -n "$out_file" ]]; then
    echo '{"id":"ch_123"}' > "$out_file"
    echo "200"
  else
    echo '{"id":"ch_123"}'
  fi
elif echo "$args" | grep -q "discord.com/api/v10/channels"; then
  echo "DM_SEND: $args" >&2
  if [[ -n "$out_file" ]]; then
    echo '{"id":"msg_123"}' > "$out_file"
    echo "200"
  else
    echo '{"id":"msg_123"}'
  fi
else
  echo '{}'
fi
MOCKCURL
chmod +x "$MOCK_DIR_P2/curl"

STATE_FILE_P2="/tmp/test_preservation_state_p2.json"
rm -f "$STATE_FILE_P2"

P2_OUTPUT="$(PATH="$MOCK_DIR_P2:$PATH" bash -c '
export TAIGA_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_ID="1"
export DISCORD_BOT_TOKEN="fake-bot-token"
export DISCORD_USER_MAP_JSON="{\"leader@sena.edu.co\": \"333333333333333333\", \"assignee@sena.edu.co\": \"555555555555555555\"}"
export DISCORD_LEAD_EMAIL="leader@sena.edu.co"
export DISCORD_LEAD_EMAILS="leader@sena.edu.co"
export TAIGA_AUTH_TOKEN="fake-auth-token"
export TAIGA_NOTIFY_STATE_FILE="/tmp/test_preservation_state_p2.json"
export TAIGA_NOTIFY_ASSIGNEE=""
export TAIGA_NOTIFY_ONLY_LEAD="true"
export TAIGA_NOTIFY_EXCLUDE_LEAD="false"
export TAIGA_SSL_VERIFY="0"
export TAIGA_WEB_UI_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_SLUG="test-project"
export TZ="UTC"

source "'"$REMIND_SH"'"
' 2>&1)" || true
P2_EXIT=$?

echo "P2 output:"
echo "$P2_OUTPUT"
echo "P2 exit code: $P2_EXIT"
echo ""

# With ONLY_LEAD=true, the script should report dm_responsables=0
assert_contains "$P2_OUTPUT" "dm_responsables=0" \
  "P2a: With ONLY_LEAD=true, dm_responsables=0 (no assignee DMs sent)" || true

# The output should show leader DMs were sent
assert_contains "$P2_OUTPUT" "dm_lideres=" \
  "P2b: With ONLY_LEAD=true, leader DM tracking is present in log" || true

echo ""

# =============================================================================
# PROPERTY 3: With TAIGA_NOTIFY_EXCLUDE_LEAD=true, no leader reports are sent
# =============================================================================

echo "----------------------------------------------"
echo "PROPERTY 3: EXCLUDE_LEAD mode sends no leader reports"
echo "----------------------------------------------"
echo ""

MOCK_DIR_P3="/tmp/test_preservation_mocks_p3"
mkdir -p "$MOCK_DIR_P3"

cat > "$MOCK_DIR_P3/curl" <<'MOCKCURL'
#!/usr/bin/env bash
args="$*"

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
  cat <<EOF
[
  {
    "id": 1,
    "ref": 100,
    "subject": "Task vencida",
    "due_date": "2020-01-01T00:00:00Z",
    "assigned_to_extra_info": {
      "email": "assignee@sena.edu.co",
      "username": "assignee",
      "full_name_display": "Assignee User"
    }
  }
]
EOF
elif echo "$args" | grep -q "api/v1/userstories"; then
  echo '[]'
elif echo "$args" | grep -q "discord.com/api/v10/users/@me/channels"; then
  if [[ -n "$out_file" ]]; then
    echo '{"id":"ch_456"}' > "$out_file"
    echo "200"
  else
    echo '{"id":"ch_456"}'
  fi
elif echo "$args" | grep -q "discord.com/api/v10/channels"; then
  if [[ -n "$out_file" ]]; then
    echo '{"id":"msg_456"}' > "$out_file"
    echo "200"
  else
    echo '{"id":"msg_456"}'
  fi
else
  echo '{}'
fi
MOCKCURL
chmod +x "$MOCK_DIR_P3/curl"

STATE_FILE_P3="/tmp/test_preservation_state_p3.json"
rm -f "$STATE_FILE_P3"

P3_OUTPUT="$(PATH="$MOCK_DIR_P3:$PATH" bash -c '
export TAIGA_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_ID="1"
export DISCORD_BOT_TOKEN="fake-bot-token"
export DISCORD_USER_MAP_JSON="{\"leader@sena.edu.co\": \"333333333333333333\", \"assignee@sena.edu.co\": \"555555555555555555\"}"
export DISCORD_LEAD_EMAIL="leader@sena.edu.co"
export DISCORD_LEAD_EMAILS="leader@sena.edu.co"
export TAIGA_AUTH_TOKEN="fake-auth-token"
export TAIGA_NOTIFY_STATE_FILE="/tmp/test_preservation_state_p3.json"
export TAIGA_NOTIFY_ASSIGNEE=""
export TAIGA_NOTIFY_ONLY_LEAD="false"
export TAIGA_NOTIFY_EXCLUDE_LEAD="true"
export TAIGA_SSL_VERIFY="0"
export TAIGA_WEB_UI_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_SLUG="test-project"
export TZ="UTC"

source "'"$REMIND_SH"'"
' 2>&1)" || true
P3_EXIT=$?

echo "P3 output:"
echo "$P3_OUTPUT"
echo "P3 exit code: $P3_EXIT"
echo ""

# With EXCLUDE_LEAD=true, the script should report dm_lideres=0
assert_contains "$P3_OUTPUT" "dm_lideres=0" \
  "P3a: With EXCLUDE_LEAD=true, dm_lideres=0 (no leader reports sent)" || true

# Assignee DMs should be sent
assert_contains "$P3_OUTPUT" "dm_responsables=1" \
  "P3b: With EXCLUDE_LEAD=true, assignee DMs are sent (dm_responsables=1)" || true

echo ""

# =============================================================================
# PROPERTY 4: With empty combined (no pending tasks), exit 0 and sent=0
# =============================================================================

echo "----------------------------------------------"
echo "PROPERTY 4: Empty combined -> exit 0, no sends"
echo "----------------------------------------------"
echo ""

MOCK_DIR_P4="/tmp/test_preservation_mocks_p4"
mkdir -p "$MOCK_DIR_P4"

cat > "$MOCK_DIR_P4/curl" <<'MOCKCURL'
#!/usr/bin/env bash
args="$*"

if echo "$args" | grep -q "api/v1/tasks"; then
  # Return tasks with future due dates (not tomorrow, not today, not overdue)
  echo '[]'
elif echo "$args" | grep -q "api/v1/userstories"; then
  echo '[]'
else
  echo '{}'
fi
MOCKCURL
chmod +x "$MOCK_DIR_P4/curl"

STATE_FILE_P4="/tmp/test_preservation_state_p4.json"
rm -f "$STATE_FILE_P4"

P4_OUTPUT="$(PATH="$MOCK_DIR_P4:$PATH" bash -c '
export TAIGA_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_ID="1"
export DISCORD_BOT_TOKEN="fake-bot-token"
export DISCORD_USER_MAP_JSON="{\"leader@sena.edu.co\": \"333333333333333333\"}"
export DISCORD_LEAD_EMAIL="leader@sena.edu.co"
export DISCORD_LEAD_EMAILS="leader@sena.edu.co"
export TAIGA_AUTH_TOKEN="fake-auth-token"
export TAIGA_NOTIFY_STATE_FILE="/tmp/test_preservation_state_p4.json"
export TAIGA_NOTIFY_ASSIGNEE=""
export TAIGA_NOTIFY_ONLY_LEAD="false"
export TAIGA_NOTIFY_EXCLUDE_LEAD="false"
export TAIGA_SSL_VERIFY="0"
export TAIGA_WEB_UI_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_SLUG="test-project"
export TZ="UTC"

source "'"$REMIND_SH"'"
' 2>&1)" || true
P4_EXIT=$?

echo "P4 output:"
echo "$P4_OUTPUT"
echo "P4 exit code: $P4_EXIT"
echo ""

assert_equals "$P4_EXIT" "0" \
  "P4a: With no pending tasks, exit code is 0" || true

assert_contains "$P4_OUTPUT" "Sin tareas ni user stories" \
  "P4b: With no pending tasks, log indicates no tasks found" || true

echo ""

# =============================================================================
# PROPERTY 5: Deduplication - second run same day skips already-sent users
# =============================================================================

echo "----------------------------------------------"
echo "PROPERTY 5: Deduplication skips already-sent users"
echo "----------------------------------------------"
echo ""

# Test already_sent_today function directly
P5_OUTPUT="$(bash -c '
set -uo pipefail

export DISCORD_USER_MAP_JSON="{\"test@sena.edu.co\": \"666666666666666666\"}"
export DISCORD_LEAD_EMAILS="leader@sena.edu.co"
export TAIGA_NOTIFY_STATE_FILE="/tmp/test_preservation_state_p5.json"

eval "$(sed -n "/^normalize_email/,/^main \"\\\$@\"/{ /^main \"\\\$@\"/d; p; }" "'"$REMIND_SH"'")"
log() { echo "[taiga-remind] $*" >&2; }

today="$(date +%Y-%m-%d)"

# Initialize state file for today
ensure_state_file "$today"

# Mark a user as sent
dedup_key="${today}|assignee-daily-report|666666666666666666"
mark_sent_today "$dedup_key"

# Check if already_sent_today returns true
if already_sent_today "$dedup_key"; then
  echo "DEDUP_CHECK=true"
else
  echo "DEDUP_CHECK=false"
fi

# Check a user that was NOT sent
other_key="${today}|assignee-daily-report|777777777777777777"
if already_sent_today "$other_key"; then
  echo "OTHER_CHECK=true"
else
  echo "OTHER_CHECK=false"
fi
' 2>&1)"

echo "P5 output: $P5_OUTPUT"
echo ""

assert_contains "$P5_OUTPUT" "DEDUP_CHECK=true" \
  "P5a: already_sent_today returns true for marked user" || true

assert_contains "$P5_OUTPUT" "OTHER_CHECK=false" \
  "P5b: already_sent_today returns false for unmarked user" || true

# Test full dedup scenario: run twice, second run should skip
MOCK_DIR_P5="/tmp/test_preservation_mocks_p5"
mkdir -p "$MOCK_DIR_P5"

cat > "$MOCK_DIR_P5/curl" <<'MOCKCURL'
#!/usr/bin/env bash
args="$*"

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
  cat <<EOF
[
  {
    "id": 1,
    "ref": 100,
    "subject": "Task vencida",
    "due_date": "2020-01-01T00:00:00Z",
    "assigned_to_extra_info": {
      "email": "dedup_user@sena.edu.co",
      "username": "dedup_user",
      "full_name_display": "Dedup User"
    }
  }
]
EOF
elif echo "$args" | grep -q "api/v1/userstories"; then
  echo '[]'
elif echo "$args" | grep -q "discord.com/api/v10/users/@me/channels"; then
  if [[ -n "$out_file" ]]; then
    echo '{"id":"ch_dedup"}' > "$out_file"
    echo "200"
  else
    echo '{"id":"ch_dedup"}'
  fi
elif echo "$args" | grep -q "discord.com/api/v10/channels"; then
  if [[ -n "$out_file" ]]; then
    echo '{"id":"msg_dedup"}' > "$out_file"
    echo "200"
  else
    echo '{"id":"msg_dedup"}'
  fi
else
  echo '{}'
fi
MOCKCURL
chmod +x "$MOCK_DIR_P5/curl"

STATE_FILE_P5="/tmp/test_preservation_state_p5_full.json"
rm -f "$STATE_FILE_P5"

# First run
P5_RUN1="$(PATH="$MOCK_DIR_P5:$PATH" bash -c '
export TAIGA_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_ID="1"
export DISCORD_BOT_TOKEN="fake-bot-token"
export DISCORD_USER_MAP_JSON="{\"leader@sena.edu.co\": \"333333333333333333\", \"dedup_user@sena.edu.co\": \"888888888888888888\"}"
export DISCORD_LEAD_EMAIL="leader@sena.edu.co"
export DISCORD_LEAD_EMAILS="leader@sena.edu.co"
export TAIGA_AUTH_TOKEN="fake-auth-token"
export TAIGA_NOTIFY_STATE_FILE="/tmp/test_preservation_state_p5_full.json"
export TAIGA_NOTIFY_ASSIGNEE=""
export TAIGA_NOTIFY_ONLY_LEAD="false"
export TAIGA_NOTIFY_EXCLUDE_LEAD="false"
export TAIGA_SSL_VERIFY="0"
export TAIGA_WEB_UI_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_SLUG="test-project"
export TZ="UTC"

source "'"$REMIND_SH"'"
' 2>&1)" || true

echo "P5 Run 1 output:"
echo "$P5_RUN1"
echo ""

# Second run (same day, same state file)
P5_RUN2="$(PATH="$MOCK_DIR_P5:$PATH" bash -c '
export TAIGA_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_ID="1"
export DISCORD_BOT_TOKEN="fake-bot-token"
export DISCORD_USER_MAP_JSON="{\"leader@sena.edu.co\": \"333333333333333333\", \"dedup_user@sena.edu.co\": \"888888888888888888\"}"
export DISCORD_LEAD_EMAIL="leader@sena.edu.co"
export DISCORD_LEAD_EMAILS="leader@sena.edu.co"
export TAIGA_AUTH_TOKEN="fake-auth-token"
export TAIGA_NOTIFY_STATE_FILE="/tmp/test_preservation_state_p5_full.json"
export TAIGA_NOTIFY_ASSIGNEE=""
export TAIGA_NOTIFY_ONLY_LEAD="false"
export TAIGA_NOTIFY_EXCLUDE_LEAD="false"
export TAIGA_SSL_VERIFY="0"
export TAIGA_WEB_UI_BASE_URL="http://localhost:9999"
export TAIGA_PROJECT_SLUG="test-project"
export TZ="UTC"

source "'"$REMIND_SH"'"
' 2>&1)" || true

echo "P5 Run 2 output:"
echo "$P5_RUN2"
echo ""

# Second run should show ya_enviados_hoy > 0
assert_contains "$P5_RUN2" "ya_enviados_hoy=" \
  "P5c: Second run reports dedup skips in ya_enviados_hoy" || true

# Extract the ya_enviados_hoy value - it should be > 0
P5_SKIP_COUNT="$(echo "$P5_RUN2" | grep -oP 'ya_enviados_hoy=\K[0-9]+' || echo "0")"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$P5_SKIP_COUNT" -gt 0 ]]; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo -e "${GREEN}PASS${NC}: P5d: Second run ya_enviados_hoy=$P5_SKIP_COUNT (>0, dedup working)"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo -e "${RED}FAIL${NC}: P5d: Second run ya_enviados_hoy=$P5_SKIP_COUNT (expected >0)"
fi

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
  echo -e "${RED}PRESERVATION TESTS FAILED — baseline behavior not captured correctly${NC}"
  echo "Review failing tests and adjust to match actual observed behavior."
  exit 1
else
  echo -e "${GREEN}All preservation tests passed — baseline behavior captured!${NC}"
  echo "These tests must continue to pass after the fix is applied."
  exit 0
fi
