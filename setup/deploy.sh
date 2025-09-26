#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
REGISTRY="${REGISTRY:-stacks.json}"

command -v jq >/dev/null 2>&1 || { echo "Please install jq"; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "Please install yq (https://github.com/mikefarah/yq)"; exit 1; }

# env defaults
PREFIX=$(yq -r '.env_defaults.prefix // "mdp"' "$REGISTRY")

OUTFILE=".stack-outputs.json"
[[ -f "$OUTFILE" ]] || echo '{}' > "$OUTFILE"

get_output() {
  local stack="$1" key="$2"
  aws cloudformation describe-stacks --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text 2>/dev/null || true
}

store_outputs() {
  local stack="$1"; shift
  local keys=("$@")
  local obj="{}"
  for k in "${keys[@]:-}"; do
    v="$(get_output "$stack" "$k")"
    obj=$(echo "$obj" | jq --arg k "$k" --arg v "$v" '. + {($k): $v}')
  done
  jq --arg s "$stack" --argjson o "$obj" '. + {($s): $o}' "$OUTFILE" > "$OUTFILE.tmp" && mv "$OUTFILE.tmp" "$OUTFILE"
}

resolve_param() {
  local val="$1"
  # env
  val="${val//'${env.prefix}'/$PREFIX}"
  # outputs
  while [[ "$val" =~ \$\{out\.([^.}]+)\.([^.}]+)\} ]]; do
    local st="${BASH_REMATCH[1]}"
    local key="${BASH_REMATCH[2]}"
    local rep
    rep=$(jq -r --arg s "$st" --arg k "$key" '.[$s][$k] // empty' "$OUTFILE")
    val="${val//\$\{out.${st}.${key}\}/$rep}"
  done
  echo "$val"
}

# Build ordered list honoring depends_on (simple multi-pass topo sort)
mapfile -t ALL_STACKS < <(yq -r '.stacks[].name' "$REGISTRY")
declare -A DONE=()

for _ in {1..20}; do
  progress=0
  for name in "${ALL_STACKS[@]}"; do
    [[ -n "${DONE[$name]:-}" ]] && continue
    mapfile -t deps < <(yq -r ".stacks[] | select(.name==\"$name\") | (.depends_on[]? // empty)" "$REGISTRY")
    ok=true
    for d in "${deps[@]:-}"; do
      [[ -n "${DONE[$d]:-}" ]] || { ok=false; break; }
    done
    $ok || continue

    template=$(yq -r ".stacks[] | select(.name==\"$name\") | .template" "$REGISTRY")
    caps=$(yq -r ".stacks[] | select(.name==\"$name\") | (.capabilities[]? // empty)" "$REGISTRY" | paste -sd ' ' -)
    mapfile -t outputs < <(yq -r ".stacks[] | select(.name==\"$name\") | (.outputs[]? // empty)" "$REGISTRY")
    mapfile -t pkeys   < <(yq -r ".stacks[] | select(.name==\"$name\") | .params | keys[]?" "$REGISTRY")

    PARAMS=()
    for pk in "${pkeys[@]:-}"; do
      raw=$(yq -r ".stacks[] | select(.name==\"$name\") | .params[\"$pk\"]" "$REGISTRY")
      val=$(resolve_param "$raw")
      PARAMS+=( "$pk=$val" )
    done

    echo ">>> Deploying $name ($template)"
    aws cloudformation deploy \
      --stack-name "$name" \
      --template-file "$template" \
      ${caps:+--capabilities $caps} \
      ${#PARAMS[@]:+--parameter-overrides "${PARAMS[@]}"}

    [[ ${#outputs[@]} -gt 0 ]] && store_outputs "$name" "${outputs[@]}"

    DONE[$name]=1
    progress=1
  done
  [[ $progress -eq 1 ]] || break
done

for s in "${ALL_STACKS[@]}"; do
  [[ -n "${DONE[$s]:-}" ]] || { echo "Dependency cycle or missing dep prevented $s"; exit 1; }
done

echo "✅ All stacks deployed."