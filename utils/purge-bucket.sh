#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <bucket-name>"; exit 1
fi
BUCKET="$1"

echo "Purging all objects, versions, and delete markers from: $BUCKET"

# Delete object versions in batches
while :; do
  VERS_JSON="$(aws s3api list-object-versions --bucket "$BUCKET" \
               --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json)"
  COUNT="$(python3 - <<PY
import json,sys
print(len(json.loads(sys.stdin.read())))
PY
<<< "$VERS_JSON")"

  if [[ "$COUNT" -eq 0 ]]; then
    echo "No object versions left."
    break
  fi

  # Build delete payload
  PAYLOAD="$(python3 - <<PY
import json,sys
objs=json.loads(sys.stdin.read())
print(json.dumps({"Objects": objs, "Quiet": True}))
PY
<<< "$VERS_JSON")"

  echo "Deleting $COUNT versions..."
  aws s3api delete-objects --bucket "$BUCKET" --delete "$PAYLOAD" >/dev/null
done

# Delete delete-markers in batches
while :; do
  MARK_JSON="$(aws s3api list-object-versions --bucket "$BUCKET" \
               --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json)"
  COUNT="$(python3 - <<PY
import json,sys
print(len(json.loads(sys.stdin.read())))
PY
<<< "$MARK_JSON")"

  if [[ "$COUNT" -eq 0 ]]; then
    echo "No delete markers left."
    break
  fi

  PAYLOAD="$(python3 - <<PY
import json,sys
objs=json.loads(sys.stdin.read())
print(json.dumps({"Objects": objs, "Quiet": True}))
PY
<<< "$MARK_JSON")"

  echo "Deleting $COUNT delete markers..."
  aws s3api delete-objects --bucket "$BUCKET" --delete "$PAYLOAD" >/dev/null
done

echo "Bucket $BUCKET is now empty."