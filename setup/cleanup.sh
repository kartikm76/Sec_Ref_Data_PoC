#!/usr/bin/env bash
# Cleanup for Market Data PoC stacks:
# - Empties versioned S3 buckets owned by the stacks
# - Deletes stacks in reverse dependency order
# Compatible with macOS Bash 3.2 (no mapfile/yq required)

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"

# Canonical stack names (MUST match manage.sh ordering)
STACK_EVENTS="${STACK_EVENTS:-mdp-s3-raw-events}"           # 00-s3-events.yml
STACK_SFN="${STACK_SFN:-mdp-sfn-stub}"                      # 01-sfn-stub.yml
STACK_WAREHOUSE="${STACK_WAREHOUSE:-mdp-warehouse-buckets}" # 02-warehouse-buckets.yml
STACK_ATHENA="${STACK_ATHENA:-mdp-athena-ddl}"              # 03-athena-ddl.yml

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; fi

# -----------------------------
# Helpers
# -----------------------------
stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1
}

list_stack_buckets() {
  # Print PhysicalResourceId of S3 buckets for a given stack (one per line)
  local stack="$1"
  aws cloudformation list-stack-resources \
    --stack-name "$stack" \
    --query "StackResourceSummaries[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
    --output text 2>/dev/null || true
}

# Force-empty a versioned bucket (objects, versions, delete-markers)
empty_versioned_bucket() {
  local B="$1"
  echo "… Emptying s3://$B"

  $DRY_RUN && { echo "DRY-RUN: would remove all objects/versions from $B"; return 0; }

  # Try to remove current objects quickly (non-versioned or latest)
  aws s3 rm "s3://$B" --recursive >/dev/null 2>&1 || true

  # Loop until no Versions/DeleteMarkers remain
  while : ; do
    # Delete versions (iterate line-wise: Key<tab>VersionId)
    local ANY=false
    local line key vid

    # Versions
    while IFS=$'\t' read -r key vid; do
      [[ -z "${key:-}" || -z "${vid:-}" ]] && continue
      ANY=true
      aws s3api delete-object --bucket "$B" --key "$key" --version-id "$vid" >/dev/null 2>&1 || true
      echo "   deleted version  $key  [$vid]"
    done < <(aws s3api list-object-versions --bucket "$B" \
            --query 'Versions[].{K:Key,V:VersionId}' \
            --output text 2>/dev/null || true)

    # Delete markers
    while IFS=$'\t' read -r key vid; do
      [[ -z "${key:-}" || -z "${vid:-}" ]] && continue
      ANY=true
      aws s3api delete-object --bucket "$B" --key "$key" --version-id "$vid" >/dev/null 2>&1 || true
      echo "   deleted marker   $key  [$vid]"
    done < <(aws s3api list-object-versions --bucket "$B" \
            --query 'DeleteMarkers[].{K:Key,V:VersionId}' \
            --output text 2>/dev/null || true)

    $ANY || break
  done

  echo "   ✅ Empty complete: s3://$B"
}

delete_stack() {
  local s="$1"
  echo "… Deleting stack $s"
  $DRY_RUN && { echo "DRY-RUN: would delete $s"; return 0; }

  aws cloudformation delete-stack --stack-name "$s" || true
  aws cloudformation wait stack-delete-complete --stack-name "$s" || true
  echo "   ✅ Deleted $s"
}

# -----------------------------
# Build plan (reverse order for deletion)
# -----------------------------
FWD=("$STACK_EVENTS" "$STACK_SFN" "$STACK_WAREHOUSE" "$STACK_ATHENA")

# We'll delete in reverse order (consumers first)
REV=()
# manual reverse loop for Bash 3.2
i=$((${#FWD[@]} - 1))
while [ "$i" -ge 0 ]; do
  REV+=("${FWD[$i]}")
  i=$((i-1))
done

# -----------------------------
# Discover all buckets to empty
# -----------------------------
declare -A BUCKETS_SEEN
BUCKET_LIST=()

echo "Buckets to consider emptying:"
for s in "${FWD[@]}"; do
  if stack_exists "$s"; then
    for b in $(list_stack_buckets "$s"); do
      if [[ -n "$b" && -z "${BUCKETS_SEEN[$b]:-}" ]]; then
        BUCKETS_SEEN["$b"]=1
        BUCKET_LIST+=("$b")
      fi
    done
  fi
done

if ((${#BUCKET_LIST[@]})); then
  for b in "${BUCKET_LIST[@]}"; do echo " - $b"; done
else
  echo " (none)"
fi
echo

# -----------------------------
# Empty buckets
# -----------------------------
for b in "${BUCKET_LIST[@]}"; do
  empty_versioned_bucket "$b"
done

# -----------------------------
# Delete stacks (reverse)
# -----------------------------
echo
echo "Deleting stacks (reverse order)…"
for s in "${REV[@]}"; do
  if stack_exists "$s"; then
    delete_stack "$s"
  else
    echo "… $s (not found, skipping)"
  fi
done

echo "✅ Cleanup complete."