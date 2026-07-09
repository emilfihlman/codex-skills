#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

json_value() {
  jq -r "$1" "$2"
}

skill_name() {
  sed -n 's/^name: //p' "$1" | head -n 1
}

check_skill_name() {
  local path="$1" expected="$2" actual
  actual="$(skill_name "$path/SKILL.md")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Wrong skill name in $path/SKILL.md: expected $expected, got $actual" >&2
    exit 1
  fi
}

check_executable() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "Script is not executable: $path" >&2
    exit 1
  fi
}

need jq
need sed
need cmp

jq . .agents/plugins/marketplace.json >/dev/null
jq . plugins/usage/.codex-plugin/plugin.json >/dev/null

[[ "$(json_value '.name' .agents/plugins/marketplace.json)" == "emilfihlman" ]]
[[ "$(json_value '.plugins[0].name' .agents/plugins/marketplace.json)" == "usage" ]]
[[ "$(json_value '.plugins[0].source.path' .agents/plugins/marketplace.json)" == "./plugins/usage" ]]
[[ "$(json_value '.name' plugins/usage/.codex-plugin/plugin.json)" == "usage" ]]
[[ "$(json_value '.skills' plugins/usage/.codex-plugin/plugin.json)" == "./skills/" ]]

check_skill_name plugins/usage/skills/check check
check_skill_name plugins/usage/skills/forecast forecast
check_skill_name plugins/usage/skills/credits credits
check_skill_name plugins/usage/skills/keepalive keepalive
check_skill_name skills/codex-usage codex-usage
check_skill_name skills/codex-forecast codex-forecast
check_skill_name skills/codex-credits codex-credits
check_skill_name skills/codex-keepalive codex-keepalive

for script in \
  plugins/usage/skills/check/scripts/show-codex-usage.sh \
  plugins/usage/skills/forecast/scripts/usage-monitor.sh \
  plugins/usage/skills/credits/scripts/show-reset-credits.sh \
  plugins/usage/skills/keepalive/scripts/keepalive.sh \
  skills/codex-usage/scripts/show-codex-usage.sh \
  skills/codex-forecast/scripts/usage-monitor.sh \
  skills/codex-credits/scripts/show-reset-credits.sh \
  skills/codex-keepalive/scripts/keepalive.sh
do
  check_executable "$script"
  bash -n "$script"
done

cmp -s plugins/usage/skills/check/scripts/show-codex-usage.sh \
  skills/codex-usage/scripts/show-codex-usage.sh
cmp -s plugins/usage/skills/credits/scripts/show-reset-credits.sh \
  skills/codex-credits/scripts/show-reset-credits.sh
cmp -s plugins/usage/skills/keepalive/scripts/keepalive.sh \
  skills/codex-keepalive/scripts/keepalive.sh

machine_path="/home/""emil"
old_marketplace="emil""-usage"
old_display="Emil ""Usage"

if find . \
  -path ./.git -prune -o \
  -type f -print0 \
  | xargs -0 grep -nE "$machine_path|$old_marketplace|$old_display" >codex-skills-check-grep-output 2>/dev/null
then
  cat codex-skills-check-grep-output >&2
  rm -f codex-skills-check-grep-output
  echo "Found machine-specific or obsolete marketplace strings." >&2
  exit 1
fi
rm -f codex-skills-check-grep-output

echo "Package check passed."
