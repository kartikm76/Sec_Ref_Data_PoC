#!/usr/bin/env bash
# Master orchestrator for MDP CloudFormation stacks
# Usage: ./manage.sh {deploy|test|outputs|logs|cleanup} [options]

set -euo pipefail

# =========================
# Defaults / Globals
# =========================
AWS_REGION="${AWS_REGION:-us-east-1}"

# Canonical stack names (in dependency order)
STACK_EVENTS_DEFAULT="mdp-s3-raw-events"       # 00-s3-events.yml
STACK_SFN_DEFAULT="mdp-sfn-stub"               # 01-sfn-stub.yml
STACK_WAREHOUSE_DEFAULT="mdp-warehouse-buckets" # 02-warehouse-buckets.yml
STACK_ATHENA_DEFAULT="mdp-athena-ddl"          # 03-athena-ddl.yml

# Allow env overrides, else use defaults
STACK_EVENTS="${STACK_EVENTS:-$STACK_EVENTS_DEFAULT}"
STACK_SFN="${STACK_SFN:-$STACK_SFN_DEFAULT}"
STACK_WAREHOUSE="${STACK_WAREHOUSE:-$STACK_WAREHOUSE_DEFAULT}"
STACK_ATHENA="${STACK_ATHENA:-$STACK_ATHENA_DEFAULT}"

# =========================
# Small helpers
# =========================
get_output() {
  # get_output <stack> <OutputKey>
  local stack="$1" key="$2"
  aws cloudformation describe-stacks --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text 2>/dev/null || true
}

print_stack_outputs() {
  # print_stack_outputs <stack>
  local stack="$1"
  aws cloudformation describe-stacks --stack-name "$stack" \
    --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" \
    --output table
}

tail_stack_logs() {
  # tail_stack_logs <stack>
  local stack="$1"
  # Show any log groups that contain this stack name and follow them
  local groups
  groups=$(aws logs describe-log-groups --log-group-name-prefix "/" \
    --query "logGroups[?contains(logGroupName, '${stack}')].logGroupName" --output text)
  if [[ -z "$groups" ]]; then
    echo "No log groups found containing '${stack}'."
    return 0
  fi
  echo "Tailing logs for groups:"
  echo "$groups" | tr '\t' '\n'
  # Tail each in background
  while IFS=$'\t' read -r lg; do
    [[ -z "$lg" ]] && continue
    echo "---- tailing: $lg ----"
    # Tail in background; press Ctrl+C to stop all
    aws logs tail "$lg" --follow --since 10m &
  done <<< "$groups"
  wait
}

# =========================
# DEPLOY
# =========================
deploy_cmd() {
  # Ordered list with dependencies respected
  local ORDER=("$STACK_EVENTS" "$STACK_SFN" "$STACK_WAREHOUSE" "$STACK_ATHENA")

  local ONLY="" FROM="" UPTO="" SKIP_LIST="" CONTINUE=false DRY=false RETRIES=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) ONLY="$2"; shift 2;;
      --from) FROM="$2"; shift 2;;
      --upto) UPTO="$2"; shift 2;;
      --skip) SKIP_LIST="$2"; shift 2;;
      --continue-on-error) CONTINUE=true; shift;;
      --retries) RETRIES="${2:-0}"; shift 2;;
      --dry-run) DRY=true; shift;;
      -h|--help)
        cat <<EOF
deploy options:
  --only <stack>            Deploy just this stack
  --from <stack>            Start at this stack, deploy onward
  --upto <stack>            Deploy up to and including this stack
  --skip <a,b,c>            Comma-separated stack names to skip
  --continue-on-error       Keep going on failures; summarize at end
  --retries N               Retry each failing stack up to N times (default 0)
  --dry-run                 Print plan only
Stacks (order): ${ORDER[*]}
EOF
        return 0;;
      *) echo "Unknown deploy arg: $1" >&2; return 2;;
    esac
  done

  # Build the plan
  local plan=()
  local seen_from=false
  IFS=',' read -r -a SKIP_ARR <<< "${SKIP_LIST:-}"

  is_skipped() {
    local s
    for s in "${SKIP_ARR[@]}"; do [[ "$1" == "$s" ]] && return 0; done
    return 1
  }

  local s
  for s in "${ORDER[@]}"; do
    # filter --only
    if [[ -n "$ONLY" && "$s" != "$ONLY" ]]; then
      continue
    fi
    # handle --from
    if [[ -n "$FROM" && $seen_from == false ]]; then
      [[ "$s" == "$FROM" ]] && seen_from=true || continue
    fi
    plan+=("$s")
    # handle --upto
    if [[ -n "$UPTO" && "$s" == "$UPTO" ]]; then
      break
    fi
  done

  # remove skips
  local filtered=()
  for s in "${plan[@]}"; do
    is_skipped "$s" || filtered+=("$s")
  done
  plan=("${filtered[@]}")

  # map stacks -> templates
  stack_template() {
    case "$1" in
      "$STACK_EVENTS")     echo "00-s3-events.yml" ;;
      "$STACK_SFN")        echo "01-sfn-stub.yml" ;;
      "$STACK_WAREHOUSE")  echo "02-warehouse-buckets.yml" ;;
      "$STACK_ATHENA")     echo "03-athena-ddl.yml" ;;
      *) return 1 ;;
    esac
  }

  # map stacks -> parameter overrides
  stack_params() {
    case "$1" in
      "$STACK_EVENTS")
        echo "Prefix=mdp"
        ;;
      "$STACK_SFN")
        # resolve from events stack
        local BB REF
        BB=$(get_output "$STACK_EVENTS" "BbRawBucketName")
        REF=$(get_output "$STACK_EVENTS" "RefinitivRawBucketName")
        echo "Prefix=mdp BbBucketName=${BB} RefBucketName=${REF}"
        ;;
      "$STACK_WAREHOUSE")
        echo "Prefix=mdp"
        ;;
      "$STACK_ATHENA")
        local WH AR
        WH=$(get_output "$STACK_WAREHOUSE" "WarehouseBucketName")
        AR=$(get_output "$STACK_WAREHOUSE" "AthenaResultsBucketName")
        echo "Prefix=mdp WarehouseBucketName=${WH} AthenaResultsBucketName=${AR} DatabaseName=bronze CreateWorkGroup=true"
        ;;
      *) return 1 ;;
    esac
  }

  echo "Deploy plan: ${plan[*]}"
  $DRY && return 0

  local failures=()
  for s in "${plan[@]}"; do
    local tpl params attempt ok=false
    tpl=$(stack_template "$s") || { echo "Unknown stack: $s"; failures+=("$s"); $CONTINUE || break; continue; }
    params=$(stack_params "$s")

    echo ">>> Deploying $s ($tpl)"
    attempt=0
    while [[ $attempt -le $RETRIES ]]; do
      if aws cloudformation deploy \
           --stack-name "$s" \
           --template-file "../cloud_formation/$tpl" \
           --capabilities CAPABILITY_NAMED_IAM \
           --parameter-overrides $params; then
        ok=true; break
      else
        echo "Deploy failed for $s (attempt $((attempt+1))/$((RETRIES+1)))"
        attempt=$((attempt+1))
        [[ $attempt -le $RETRIES ]] && sleep 5
      fi
    done
    if ! $ok; then
      failures+=("$s")
      $CONTINUE || break
    fi
  done

  if ((${#failures[@]})); then
    echo "❌ Failed stacks: ${failures[*]}"
    return 1
  fi
  echo "✅ Deploy finished."
}

# =========================
# TEST (delegates to tests.sh)
# =========================
test_cmd() {
  if [[ ! -x "./tests.sh" ]]; then
    echo "tests.sh not found or not executable. Make sure it exists and chmod +x tests.sh"
    return 2
  fi
  ./tests.sh "$@"
}

# =========================
# OUTPUTS
# =========================
outputs_cmd() {
  local stack=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack) stack="$2"; shift 2;;
      -h|--help)
        echo "Usage: $0 outputs --stack <stack-name>"
        return 0;;
      *) echo "Unknown outputs arg: $1" >&2; return 2;;
    esac
  done
  if [[ -z "$stack" ]]; then
    echo "Specify a stack with --stack <name>"
    return 2
  fi
  print_stack_outputs "$stack"
}

# =========================
# LOGS
# =========================
logs_cmd() {
  local stack=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack) stack="$2"; shift 2;;
      -h|--help)
        echo "Usage: $0 logs --stack <stack-name>"
        return 0;;
      *) echo "Unknown logs arg: $1" >&2; return 2;;
    esac
  done
  if [[ -z "$stack" ]]; then
    echo "Specify a stack with --stack <name>"
    return 2
  fi
  tail_stack_logs "$stack"
}

# =========================
# CLEANUP (delegates to cleanup.sh)
# =========================
cleanup_cmd() {
  if [[ ! -x "./cleanup.sh" ]]; then
    echo "cleanup.sh not found or not executable. Make sure it exists and chmod +x cleanup.sh"
    return 2
  fi
  ./cleanup.sh "$@"
}

# =========================
# Dispatcher
# =========================
case "${1:-}" in
  cleanup)  shift; cleanup_cmd "$@";  exit $? ;;
  deploy)   shift; deploy_cmd "$@";   exit $? ;;
  test)     shift; test_cmd "$@";     exit $? ;;
  outputs)  shift; outputs_cmd "$@";  exit $? ;;
  logs)     shift; logs_cmd "$@";     exit $? ;;
  *)
    echo "Usage: $0 {deploy|test|outputs|logs|cleanup} [options]"
    exit 2
    ;;
esac