#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
umask 077

mode="sync"
case "${1:-}" in
  "") ;;
  --check) mode="check" ;;
  *) echo "Usage: scripts/sync-variants.sh [--check]" >&2; exit 2 ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM
failed=0

publish() {
  local generated="$1" destination="$2" permissions="$3"
  if cmp -s "$generated" "$destination"; then
    return
  fi

  if [[ "$mode" == "check" ]]; then
    echo "Generated variant is stale: $destination" >&2
    diff -u "$destination" "$generated" >&2 || true
    failed=1
    return
  fi

  install -m "$permissions" "$generated" "$destination"
  echo "Updated $destination"
}

render_usage_skill() {
  sed \
    -e 's/^name: codex-usage$/name: check/' \
    -e 's/Use \$codex-credits instead/Use $usage:credits instead/' \
    -e 's/^# Codex Usage$/# Usage Check/' \
    -e 's/\$codex-credits/\$usage:credits/g' \
    skills/codex-usage/SKILL.md
}

render_credits_skill() {
  sed \
    -e 's/^name: codex-credits$/name: credits/' \
    -e 's/Use \$codex-usage instead/Use $usage:check instead/' \
    -e 's/^# Codex Credits$/# Usage Credits/' \
    skills/codex-credits/SKILL.md
}

render_forecast_skill() {
  sed \
    -e 's/^name: codex-forecast$/name: forecast/' \
    -e 's/Use \$codex-usage for/Use $usage:check for/' \
    -e 's/^# Codex Forecast$/# Usage Forecast/' \
    -e 's/\$codex-usage/\$usage:check/g' \
    skills/codex-forecast/SKILL.md
}

render_keepalive_skill() {
  sed \
    -e 's/^name: codex-keepalive$/name: keepalive/' \
    -e 's/^# Codex Keepalive$/# Usage Keepalive/' \
    -e 's/\$codex-forecast/\$usage:forecast/g' \
    skills/codex-keepalive/SKILL.md
}

render_usage_yaml() {
  sed \
    -e 's/display_name: "Codex Usage"/display_name: "Usage Check"/' \
    -e 's/\$codex-usage/\$usage:check/g' \
    skills/codex-usage/agents/openai.yaml
}

render_credits_yaml() {
  sed \
    -e 's/display_name: "Codex Credits"/display_name: "Usage Credits"/' \
    -e 's/\$codex-credits/\$usage:credits/g' \
    skills/codex-credits/agents/openai.yaml
}

render_forecast_yaml() {
  sed \
    -e 's/display_name: "Codex Forecast"/display_name: "Usage Forecast"/' \
    -e 's/\$codex-forecast/\$usage:forecast/g' \
    skills/codex-forecast/agents/openai.yaml
}

render_keepalive_yaml() {
  sed \
    -e 's/display_name: "Codex Keepalive"/display_name: "Usage Keepalive"/' \
    -e 's/\$codex-keepalive/\$usage:keepalive/g' \
    skills/codex-keepalive/agents/openai.yaml
}

mkdir -p \
  "$tmp_dir/check/agents" \
  "$tmp_dir/credits/agents" \
  "$tmp_dir/forecast/agents" \
  "$tmp_dir/keepalive/agents"

render_usage_skill >"$tmp_dir/check/SKILL.md"
render_credits_skill >"$tmp_dir/credits/SKILL.md"
render_forecast_skill >"$tmp_dir/forecast/SKILL.md"
render_keepalive_skill >"$tmp_dir/keepalive/SKILL.md"
render_usage_yaml >"$tmp_dir/check/agents/openai.yaml"
render_credits_yaml >"$tmp_dir/credits/agents/openai.yaml"
render_forecast_yaml >"$tmp_dir/forecast/agents/openai.yaml"
render_keepalive_yaml >"$tmp_dir/keepalive/agents/openai.yaml"

publish "$tmp_dir/check/SKILL.md" plugins/usage/skills/check/SKILL.md 0644
publish "$tmp_dir/credits/SKILL.md" plugins/usage/skills/credits/SKILL.md 0644
publish "$tmp_dir/forecast/SKILL.md" plugins/usage/skills/forecast/SKILL.md 0644
publish "$tmp_dir/keepalive/SKILL.md" plugins/usage/skills/keepalive/SKILL.md 0644
publish "$tmp_dir/check/agents/openai.yaml" plugins/usage/skills/check/agents/openai.yaml 0644
publish "$tmp_dir/credits/agents/openai.yaml" plugins/usage/skills/credits/agents/openai.yaml 0644
publish "$tmp_dir/forecast/agents/openai.yaml" plugins/usage/skills/forecast/agents/openai.yaml 0644
publish "$tmp_dir/keepalive/agents/openai.yaml" plugins/usage/skills/keepalive/agents/openai.yaml 0644

publish skills/codex-usage/scripts/show-codex-usage.sh \
  plugins/usage/skills/check/scripts/show-codex-usage.sh 0755
publish skills/codex-credits/scripts/show-reset-credits.sh \
  plugins/usage/skills/credits/scripts/show-reset-credits.sh 0755
publish skills/codex-forecast/scripts/usage-monitor.sh \
  plugins/usage/skills/forecast/scripts/usage-monitor.sh 0755
publish skills/codex-keepalive/scripts/keepalive.sh \
  plugins/usage/skills/keepalive/scripts/keepalive.sh 0755

if [[ "$failed" -ne 0 ]]; then
  echo "Run scripts/sync-variants.sh to regenerate plugin variants." >&2
  exit 1
fi

if [[ "$mode" == "check" ]]; then
  echo "Generated variants are current."
fi
