#!/usr/bin/env bash
set -euo pipefail
echo "[fix-tier] Starting tier patch script (bulk mode)" >&2
TIER_ENV_VAR=${DEPLOYMENT_TIER:-${TIER:-}}
if [ -z "${TIER_ENV_VAR}" ]; then
  echo "[fix-tier] No DEPLOYMENT_TIER/TIER set; skipping (non-fatal)." >&2
  exit 0
fi
JQ_FILTER='.
  | .tier = $tier
  | .infra = ( .infra // {} )
  | .infra.parameters = ( .infra.parameters // {} )
  | .infra.parameters.tier = $tier'

PATCHED=0
for cfg in .azure/*/config.json .azure/config.json; do
  [ -f "$cfg" ] || continue
  TMP=$(mktemp)
  if jq --arg tier "$TIER_ENV_VAR" "$JQ_FILTER" "$cfg" > "$TMP" 2>/dev/null; then
    mv "$TMP" "$cfg"
    echo "[fix-tier] Patched $cfg -> tier=$TIER_ENV_VAR" >&2
    PATCHED=$((PATCHED+1))
  else
    echo "[fix-tier] Skipped (jq fail) $cfg" >&2
    rm -f "$TMP"
  fi
done
echo "[fix-tier] Completed. Patched $PATCHED config file(s)." >&2
exit 0
