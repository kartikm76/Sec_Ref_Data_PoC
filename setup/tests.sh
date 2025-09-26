#!/usr/bin/env bash
# End-to-end smoke tests for Raw -> EventBridge -> SQS and optional Athena checks.
# Supports draining, auto-delete, printing uploaded keys, and JSON-only output.

set -euo pipefail

# -----------------------------
# Defaults (override via env)
# -----------------------------
: "${AWS_REGION:=us-east-1}"
: "${PREFIX:=mdp}"

STACK_EVENTS="${STACK_EVENTS:-mdp-s3-raw-events}"           # 00-s3-eventsyml
STACK_WAREHOUSE="${STACK_WAREHOUSE:-mdp-warehouse-buckets}" # 02-warehouse-buckets.yml
STACK_ATHENA="${STACK_ATHENA:-mdp-athena-ddl}"              # 03-athena-ddl.yml

VENDOR="both"        # bb | ref | both
PURGE=false
DO_ATHENA=true
MAX_WAIT=20
DELETE_AFTER=false
DRAIN_FIRST=false
DRAIN_AFTER=false
DRAIN_ONLY=false
PRINT_KEYS=false
JSON_ONLY=false
EVENTS_STACK_OVERRIDE=""

# -----------------------------
# Args
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vendor)        VENDOR="${2:-both}"; shift 2;;
    --purge)         PURGE=true; shift;;
    --no-athena)     DO_ATHENA=false; shift;;
    --max-wait)      MAX_WAIT="${2:-20}"; shift 2;;
    --delete-after)  DELETE_AFTER=true; shift;;
    --drain-first)   DRAIN_FIRST=true; shift;;
    --drain-after)   DRAIN_AFTER=true; shift;;
    --drain-only)    DRAIN_ONLY=true; shift;;
    --print-keys)    PRINT_KEYS=true; shift;;
    --json-only)     JSON_ONLY=true; shift;;
    --events-stack)  EVENTS_STACK_OVERRIDE="${2}"; shift 2;;
    -h|--help)
      cat <<EOF
Usage: $0 [options]
  --vendor bb|ref|both     Which vendor(s) to test (default: both)
  --purge                  Purge SQS before tests
  --drain-first            Drain SQS (receive+delete) before tests
  --drain-after            Drain SQS after tests
  --drain-only             Only drain SQS and exit
  --delete-after           Auto-delete fetched SQS messages
  --no-athena              Skip Athena checks
  --max-wait N             Wait up to N seconds for SQS after each upload (default 20)
  --print-keys             Print uploaded S3 object keys
  --json-only              Emit only JSON (raw SQS messages; keys as JSON if --print-keys)
  --events-stack NAME      Use a non-default events stack name
EOF
      exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

# -----------------------------
# Logging helpers
# -----------------------------
log()   { $JSON_ONLY || echo -e "$*"; }
pretty(){ $JSON_ONLY || echo -e "\n========== $* ==========\n"; }

# -----------------------------
# Utility helpers
# -----------------------------
get_output() {
  local stack="$1" key="$2"
  aws cloudformation describe-stacks --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text 2>/dev/null || true
}

poll_sqs_one() {
  local qurl="$1" timeout="$2"
  aws sqs receive-message \
    --queue-url "$qurl" \
    --max-number-of-messages 1 \
    --wait-time-seconds "$timeout" \
    --output json
}

drain_queue() {
  local qurl="$1"
  command -v jq >/dev/null 2>&1 || { log "jq is required for --drain-*"; return 1; }
  pretty "Draining SQS queue: $qurl"
  while true; do
    local msg
    msg=$(aws sqs receive-message --queue-url "$qurl" \
            --max-number-of-messages 1 --wait-time-seconds 2 --output json)
    if [[ -z "$msg" || "$msg" == "{}" ]]; then
      log "Queue empty ✅"
      break
    fi
    if $JSON_ONLY; then
      echo "$msg"
    else
      local body handle
      body=$(echo "$msg" | jq -r '.Messages[0].Body')
      handle=$(echo "$msg" | jq -r '.Messages[0].ReceiptHandle')
      echo "Message:"
      echo "$body"
      log "Deleting…"
    fi
    local handle
    handle=$(echo "$msg" | jq -r '.Messages[0].ReceiptHandle')
    aws sqs delete-message --queue-url "$qurl" --receipt-handle "$handle" >/dev/null
    $JSON_ONLY || log "Deleted above message"
  done
}

upload_ref() {
  local now_utc y m d t key
  now_utc=$(date -u +%H:%M:%S)
  y=$(date +%Y); m=$(date +%m); d=$(date +%d); t=$(date +%s)
  echo "ref $now_utc" > /tmp/ref.txt
  key="dataset=secref/year=${y}/month=${m}/day=${d}/ref-${t}.txt"
  $JSON_ONLY || log "Uploading to s3://${REF_BUCKET}/${key}"
  aws s3 cp /tmp/ref.txt "s3://${REF_BUCKET}/${key}" >/dev/null
  echo "$key"
}

upload_bb() {
  local now_utc y m d t key
  now_utc=$(date -u +%H:%M:%S)
  y=$(date +%Y); m=$(date +%m); d=$(date +%d); t=$(date +%s)
  echo "bb  $now_utc" > /tmp/bb.txt
  key="dataset=secref/year=${y}/month=${m}/day=${d}/bb-${t}.txt"
  $JSON_ONLY || log "Uploading to s3://${BB_BUCKET}/${key}"
  aws s3 cp /tmp/bb.txt "s3://${BB_BUCKET}/${key}" >/dev/null
  echo "$key"
}

maybe_delete() {
  local qurl="$1" msg_json="$2"
  $DELETE_AFTER || return 0
  command -v jq >/dev/null 2>&1 || { log "jq required for --delete-after"; return 1; }
  local handle
  handle=$(echo "$msg_json" | jq -r '.Messages[0].ReceiptHandle // empty')
  [[ -z "$handle" || "$handle" == "null" ]] && return 0
  aws sqs delete-message --queue-url "$qurl" --receipt-handle "$handle" >/dev/null
  $JSON_ONLY || log "Deleted message (auto, --delete-after)."
}

# -----------------------------
# Resolve infra outputs (after args)
# -----------------------------
STACK_EVENTS_EFF="${EVENTS_STACK_OVERRIDE:-$STACK_EVENTS}"

BB_BUCKET=$(get_output "$STACK_EVENTS_EFF" "BbRawBucketName")
REF_BUCKET=$(get_output "$STACK_EVENTS_EFF" "RefinitivRawBucketName")
RAW_TAP_QURL=$(get_output "$STACK_EVENTS_EFF" "RawDataQueueUrl")
ATHENA_RESULTS_BUCKET=$(get_output "$STACK_WAREHOUSE" "AthenaResultsBucketName")

if [[ -z "$RAW_TAP_QURL" || -z "$BB_BUCKET" || -z "$REF_BUCKET" ]]; then
  $JSON_ONLY || echo "ERROR: Could not resolve outputs from $STACK_EVENTS_EFF (or wrong region)."
  exit 1
fi

$JSON_ONLY || {
  echo "Resolved:"
  echo "  BB_BUCKET           = $BB_BUCKET"
  echo "  REF_BUCKET          = $REF_BUCKET"
  echo "  RAW_TAP_QURL        = $RAW_TAP_QURL"
  echo "  ATHENA_RESULTS_S3   = ${ATHENA_RESULTS_BUCKET:-<none>}"
  echo
}

# -----------------------------
# Drain-only path
# -----------------------------
if $DRAIN_ONLY; then
  drain_queue "$RAW_TAP_QURL"
  exit 0
fi

# Optional purge
if $PURGE; then
  pretty "Purging SQS queue (server-side)…"
  aws sqs purge-queue --queue-url "$RAW_TAP_QURL" || true
  sleep 5
fi

# Optional drain-first
$DRAIN_FIRST && drain_queue "$RAW_TAP_QURL"

# -----------------------------
# Tests
# -----------------------------
if [[ "$VENDOR" == "ref" || "$VENDOR" == "both" ]]; then
  pretty "EventBridge → SQS (Refinitiv)"
  REF_KEY=$(upload_ref)
  $JSON_ONLY || log "Waiting up to ${MAX_WAIT}s for SQS message…"
  MSG=$(poll_sqs_one "$RAW_TAP_QURL" "$MAX_WAIT")
  echo "$MSG"
  maybe_delete "$RAW_TAP_QURL" "$MSG"
  $PRINT_KEYS && { $JSON_ONLY && jq -nc --arg key "$REF_KEY" '{uploaded_keys:[$key]}' || echo "REFINITIV_S3_KEY=${REF_KEY}"; }
fi

if [[ "$VENDOR" == "bb" || "$VENDOR" == "both" ]]; then
  pretty "EventBridge → SQS (Bloomberg)"
  BB_KEY=$(upload_bb)
  $JSON_ONLY || log "Waiting up to ${MAX_WAIT}s for SQS message…"
  MSG=$(poll_sqs_one "$RAW_TAP_QURL" "$MAX_WAIT")
  echo "$MSG"
  maybe_delete "$RAW_TAP_QURL" "$MSG"
  $PRINT_KEYS && { $JSON_ONLY && jq -nc --arg key "$BB_KEY" '{uploaded_keys:[$key]}' || echo "BLOOMBERG_S3_KEY=${BB_KEY}"; }
fi

# -----------------------------
# Athena quick checks (optional)
# -----------------------------
if $DO_ATHENA; then
  if [[ -z "${ATHENA_RESULTS_BUCKET:-}" ]]; then
    $JSON_ONLY || echo "Skipping Athena checks (results bucket not found in $STACK_WAREHOUSE)."
  else
    pretty "Athena quick checks"
    $JSON_ONLY || echo "SHOW DATABASES;"
    aws athena start-query-execution \
      --query-string "SHOW DATABASES;" \
      --result-configuration "OutputLocation=s3://${ATHENA_RESULTS_BUCKET}/athena/" \
      >/dev/null
    $JSON_ONLY || echo "SHOW TABLES IN bronze;"
    aws athena start-query-execution \
      --query-string "SHOW TABLES IN bronze;" \
      --result-configuration "OutputLocation=s3://${ATHENA_RESULTS_BUCKET}/athena/" \
      >/dev/null
    $JSON_ONLY || echo "(Open Athena console to view results under the results bucket.)"
  fi
fi

$DRAIN_AFTER && drain_queue "$RAW_TAP_QURL"

$JSON_ONLY || { echo; echo "✅ Tests finished."; }