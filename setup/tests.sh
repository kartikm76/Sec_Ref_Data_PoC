#!/usr/bin/env bash
# End-to-end tests:
# - S3 → EventBridge → SQS (Bloomberg/Refinitiv)
# - Optional Athena smoke (SHOW DB/TABLES), inserts, queries, and cleanup
# Requirements: AWS CLI v2, jq

set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${STACK_EVENTS:=mdp-s3-raw-events}"
: "${STACK_WAREHOUSE:=mdp-warehouse-buckets}"
: "${STACK_ATHENA:=mdp-athena-ddl}"

VENDOR="both"        # bb | ref | both
MAX_WAIT=20
DELETE_AFTER=false
DRAIN_FIRST=false
PRINT_KEYS=false
JSON_ONLY=false

# Athena flags (opt-in)
DO_ATHENA=false
ATHENA_SMOKE=false
ATHENA_INSERT=false
ATHENA_QUERY=false
ATHENA_CLEAN=false

usage() {
  cat <<EOF
Usage: $0 [options]

S3/EB/SQS:
  --vendor bb|ref|both     Which vendor(s) to test (default: both)
  --max-wait N             Wait up to N seconds for SQS after each upload (default 20)
  --delete-after           Delete fetched SQS messages
  --drain-first            Drain SQS before tests
  --print-keys             Print uploaded S3 object keys
  --json-only              Emit only JSON

Athena:
  --athena                 Enable Athena checks (same as --athena-smoke --athena-insert --athena-query)
  --athena-smoke           SHOW DATABASES, SHOW TABLES IN bronze
  --athena-insert          Insert 1 demo row into bronze.secref_bonds_bb and bronze.secref_bonds_ref
  --athena-query           Run COUNT + sample SELECT from both tables
  --athena-clean           Delete inserted rows by ingest_id

Examples:
  $0 --vendor both --print-keys --delete-after
  $0 --athena                           # smoke + insert + query
  $0 --athena --athena-clean            # smoke + insert + query + delete rows
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vendor)        VENDOR="${2:-both}"; shift 2;;
    --max-wait)      MAX_WAIT="${2:-20}"; shift 2;;
    --delete-after)  DELETE_AFTER=true; shift;;
    --drain-first)   DRAIN_FIRST=true; shift;;
    --print-keys)    PRINT_KEYS=true; shift;;
    --json-only)     JSON_ONLY=true; shift;;

    --athena)        DO_ATHENA=true; ATHENA_SMOKE=true; ATHENA_INSERT=true; ATHENA_QUERY=true; shift;;
    --athena-smoke)  DO_ATHENA=true; ATHENA_SMOKE=true; shift;;
    --athena-insert) DO_ATHENA=true; ATHENA_INSERT=true; shift;;
    --athena-query)  DO_ATHENA=true; ATHENA_QUERY=true; shift;;
    --athena-clean)  DO_ATHENA=true; ATHENA_CLEAN=true; shift;;

    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

req() { command -v "$1" >/dev/null 2>&1 || { echo "Please install $1"; exit 1; }; }
req jq

log()   { $JSON_ONLY || echo -e "$*"; }
pretty(){ $JSON_ONLY || echo -e "\n========== $* ==========\n"; }

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
  pretty "Draining SQS queue: $qurl"
  while true; do
    local msg
    msg=$(aws sqs receive-message --queue-url "$qurl" \
            --max-number-of-messages 1 --wait-time-seconds 2 --output json)
    if [[ -z "$msg" || "$msg" == "{}" ]] ; then
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
  local handle
  handle=$(echo "$msg_json" | jq -r '.Messages[0].ReceiptHandle // empty')
  [[ -z "$handle" || "$handle" == "null" ]] && return 0
  aws sqs delete-message --queue-url "$qurl" --receipt-handle "$handle" >/dev/null
  $JSON_ONLY || log "Deleted message (auto, --delete-after)."
}

# -----------------------------
# Resolve infra outputs
# -----------------------------
BB_BUCKET=$(get_output "$STACK_EVENTS" "BbRawBucketName")
REF_BUCKET=$(get_output "$STACK_EVENTS" "RefinitivRawBucketName")
RAW_TAP_QURL=$(get_output "$STACK_EVENTS" "RawDataQueueUrl")
ATHENA_RESULTS_BUCKET=$(get_output "$STACK_WAREHOUSE" "AthenaResultsBucketName")
ATHENA_WG=$(get_output "$STACK_ATHENA" "WorkGroupName")
[[ -z "$ATHENA_WG" || "$ATHENA_WG" == "None" ]] && ATHENA_WG="primary"

if [[ -z "$RAW_TAP_QURL" || -z "$BB_BUCKET" || -z "$REF_BUCKET" ]]; then
  $JSON_ONLY || echo "ERROR: Could not resolve outputs from $STACK_EVENTS (or wrong region)."
  exit 1
fi

$JSON_ONLY || {
  echo "Resolved:"
  echo "  BB_BUCKET            = $BB_BUCKET"
  echo "  REF_BUCKET           = $REF_BUCKET"
  echo "  RAW_TAP_QURL         = $RAW_TAP_QURL"
  echo "  ATHENA_RESULTS_S3    = ${ATHENA_RESULTS_BUCKET:-<none>}"
  echo "  ATHENA_WORKGROUP     = $ATHENA_WG"
  echo
}

# -----------------------------
# Drain-first path
# -----------------------------
$DRAIN_FIRST && drain_queue "$RAW_TAP_QURL"

# -----------------------------
# S3 → EB → SQS tests
# -----------------------------
REF_KEY=""; BB_KEY=""

if [[ "$VENDOR" == "ref" || "$VENDOR" == "both" ]]; then
  pretty "EventBridge → SQS (Refinitiv)"
  REF_KEY=$(upload_ref)
  $JSON_ONLY || log "Waiting up to ${MAX_WAIT}s for SQS message…"
  MSG=$(poll_sqs_one "$RAW_TAP_QURL" "$MAX_WAIT")
  $JSON_ONLY && echo "$MSG" || echo "$MSG"
  maybe_delete "$RAW_TAP_QURL" "$MSG"
fi

if [[ "$VENDOR" == "bb" || "$VENDOR" == "both" ]]; then
  pretty "EventBridge → SQS (Bloomberg)"
  BB_KEY=$(upload_bb)
  $JSON_ONLY || log "Waiting up to ${MAX_WAIT}s for SQS message…"
  MSG=$(poll_sqs_one "$RAW_TAP_QURL" "$MAX_WAIT")
  $JSON_ONLY && echo "$MSG" || echo "$MSG"
  maybe_delete "$RAW_TAP_QURL" "$MSG"
fi

$PRINT_KEYS && {
  if $JSON_ONLY; then
    jq -nc --arg ref "${REF_KEY:-}" --arg bb "${BB_KEY:-}" \
      '{uploaded_keys: ([$ref, $bb] | map(select(. != "")))}'
  else
    [[ -n "${REF_KEY:-}" ]] && echo "REFINITIV_S3_KEY=${REF_KEY}"
    [[ -n "${BB_KEY:-}"  ]] && echo "BLOOMBERG_S3_KEY=${BB_KEY}"
  fi
}

# -----------------------------
# Athena helpers
# -----------------------------
athena_exec() {
  local sql="$1"
  local qid
  qid=$(aws athena start-query-execution \
          --query-string "$sql" \
          --work-group "$ATHENA_WG" \
          --result-configuration "OutputLocation=s3://${ATHENA_RESULTS_BUCKET}/athena/" \
          --query "QueryExecutionId" --output text)
  # poll
  while true; do
    sleep 2
    local state
    state=$(aws athena get-query-execution --query-execution-id "$qid" \
              --query "QueryExecution.Status.State" --output text)
    case "$state" in
      SUCCEEDED) echo "$qid"; return 0;;
      FAILED|CANCELLED)
        aws athena get-query-execution --query-execution-id "$qid" --output json
        return 1;;
    esac
  done
}

athena_show_result() {
  local qid="$1"
  aws athena get-query-results --query-execution-id "$qid" --output table
}

RUN_ID="run-$RANDOM-$RANDOM"   # used in inserts and cleanup

# -----------------------------
# Athena tests (optional)
# -----------------------------
if $DO_ATHENA; then
  if [[ -z "${ATHENA_RESULTS_BUCKET:-}" ]]; then
    echo "Skipping Athena (no results bucket output)."
    exit 0
  fi

  if $ATHENA_SMOKE; then
    pretty "Athena SMOKE"
    Q=$(athena_exec "SHOW DATABASES;"); athena_show_result "$Q"
    Q=$(athena_exec "SHOW TABLES IN bronze;"); athena_show_result "$Q"
  fi

  if $ATHENA_INSERT; then
    pretty "Athena INSERT sample rows"
    # Bloomberg
    SQL_BB=$(cat <<'EOSQL'
INSERT INTO bronze.secref_bonds_bb (
  vendor, dataset, file_date, source_bucket, source_key, load_ts, ingest_id,
  isin, cusip, sedol, ticker, bbg_figi, issuer_name, instrument_type, currency,
  day_count, coupon_type, coupon, face_value, issue_dt, maturity_dt, first_coupon_dt,
  callable, puttable, seniority, is_valid, reason_code, reason_detail
) VALUES (
  'bloomberg','secref', DATE '2025-09-24',
  '${BB_BUCKET}','dataset=secref/year=2025/month=09/day=24/bb-demo.csv',
  CAST(current_timestamp AS timestamp), '${RUN_ID}',
  'US037833DJ16','037833DJ1','2046251','AAPL','BBG000B9XRY4','Apple Inc','CorporateBond','USD',
  '30/360','Fixed', CAST(3.5000 AS DECIMAL(8,4)), CAST(1000.0000 AS DECIMAL(18,4)),
  DATE '2020-04-01', DATE '2027-05-01', DATE '2020-10-01',
  TRUE, FALSE, 'Senior Unsecured', TRUE, NULL, NULL
);
EOSQL
)
    SQL_BB=${SQL_BB//'${BB_BUCKET}'/$BB_BUCKET}
    SQL_BB=${SQL_BB//'${RUN_ID}'/$RUN_ID}
    Q=$(athena_exec "$SQL_BB"); athena_show_result "$Q"

    # Refinitiv
    SQL_REF=$(cat <<'EOSQL'
INSERT INTO bronze.secref_bonds_ref (
  vendor, dataset, file_date, source_bucket, source_key, load_ts, ingest_id,
  isin, cusip, sedol, ric, ticker, bbg_figi,
  issuer_name, instrument_type, currency, day_count, coupon_type,
  coupon, face_value, issue_dt, maturity_dt, first_coupon_dt,
  callable, puttable, seniority, is_valid, reason_code, reason_detail
) VALUES (
  'refinitiv','secref', DATE '2025-09-24',
  '${REF_BUCKET}','dataset=secref/year=2025/month=09/day=24/ref-demo.csv',
  CAST(current_timestamp AS timestamp), '${RUN_ID}',
  'US037833DJ16','037833DJ1','2046251','AAPL.O','AAPL','BBG000B9XRY4',
  'Apple Inc','CorporateBond','USD','30/360','Fixed',
  CAST(3.5000 AS DECIMAL(8,4)), CAST(1000.0000 AS DECIMAL(18,4)),
  DATE '2020-04-01', DATE '2027-05-01', DATE '2020-10-01',
  TRUE, FALSE, 'Senior Unsecured', TRUE, NULL, NULL
);
EOSQL
)
    SQL_REF=${SQL_REF//'${REF_BUCKET}'/$REF_BUCKET}
    SQL_REF=${SQL_REF//'${RUN_ID}'/$RUN_ID}
    Q=$(athena_exec "$SQL_REF"); athena_show_result "$Q"
  fi

  if $ATHENA_QUERY; then
    pretty "Athena COUNT + sample"
    Q=$(athena_exec "SELECT 'bb' AS t, count(*) c FROM bronze.secref_bonds_bb UNION ALL SELECT 'ref', count(*) FROM bronze.secref_bonds_ref;")
    athena_show_result "$Q"
    Q=$(athena_exec "SELECT * FROM bronze.secref_bonds_bb ORDER BY load_ts DESC LIMIT 3;")
    athena_show_result "$Q"
    Q=$(athena_exec "SELECT * FROM bronze.secref_bonds_ref ORDER BY load_ts DESC LIMIT 3;")
    athena_show_result "$Q"
  fi

  if $ATHENA_CLEAN; then
    pretty "Athena DELETE inserted rows (ingest_id=${RUN_ID})"
    Q=$(athena_exec "DELETE FROM bronze.secref_bonds_bb  WHERE ingest_id='${RUN_ID}';"); athena_show_result "$Q"
    Q=$(athena_exec "DELETE FROM bronze.secref_bonds_ref WHERE ingest_id='${RUN_ID}';"); athena_show_result "$Q"
  fi
fi

$JSON_ONLY || { echo; echo "✅ Tests finished."; }