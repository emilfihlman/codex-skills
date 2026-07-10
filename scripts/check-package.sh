#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

fail() {
  echo "$*" >&2
  exit 1
}

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

check_skill() {
  local path="$1" expected="$2" invocation="$3" actual short
  actual="$(skill_name "$path/SKILL.md")"
  [[ "$actual" == "$expected" ]] ||
    fail "Wrong skill name in $path/SKILL.md: expected $expected, got $actual"

  grep -q '^description: .\+' "$path/SKILL.md" ||
    fail "Missing skill description: $path/SKILL.md"
  grep -q '^  display_name: "[^"]\+"$' "$path/agents/openai.yaml" ||
    fail "Missing quoted display_name: $path/agents/openai.yaml"
  grep -q '^  short_description: "[^"]\+"$' "$path/agents/openai.yaml" ||
    fail "Missing quoted short_description: $path/agents/openai.yaml"
  grep -Fq "$invocation" "$path/agents/openai.yaml" ||
    fail "Default prompt does not mention $invocation: $path/agents/openai.yaml"

  short="$(sed -n 's/^  short_description: "\(.*\)"$/\1/p' "$path/agents/openai.yaml")"
  (( ${#short} >= 25 && ${#short} <= 64 )) ||
    fail "short_description must be 25-64 characters: $path/agents/openai.yaml"

  if awk '
    NR == 1 && $0 == "---" { in_frontmatter=1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && $0 !~ /^(name|description): / { exit 1 }
  ' "$path/SKILL.md"; then
    :
  else
    fail "SKILL.md frontmatter contains unsupported fields: $path/SKILL.md"
  fi
}

check_script() {
  local path="$1"
  [[ -x "$path" ]] || fail "Script is not executable: $path"
  bash -n "$path"
}

for command in bash jq sed awk grep head mktemp rg git cmp diff install; do
  need "$command"
done

jq -e . .agents/plugins/marketplace.json >/dev/null
jq -e . plugins/usage/.codex-plugin/plugin.json >/dev/null

marketplace=.agents/plugins/marketplace.json
manifest=plugins/usage/.codex-plugin/plugin.json

[[ "$(json_value '.name' "$marketplace")" == "emilfihlman" ]] || fail "Wrong marketplace name"
[[ "$(json_value '.plugins | length' "$marketplace")" == "1" ]] || fail "Expected one marketplace plugin"
[[ "$(json_value '.plugins[0].name' "$marketplace")" == "usage" ]] || fail "Wrong marketplace plugin name"
[[ "$(json_value '.plugins[0].source.source' "$marketplace")" == "local" ]] || fail "Marketplace source must be local"
[[ "$(json_value '.plugins[0].source.path' "$marketplace")" == "./plugins/usage" ]] || fail "Wrong marketplace source path"
jq -e '.plugins[0].policy.installation | IN("NOT_AVAILABLE", "AVAILABLE", "INSTALLED_BY_DEFAULT")' "$marketplace" >/dev/null
jq -e '.plugins[0].policy.authentication | IN("ON_INSTALL", "ON_USE")' "$marketplace" >/dev/null
jq -e '.plugins[0].category | type == "string" and length > 0' "$marketplace" >/dev/null

[[ "$(json_value '.name' "$manifest")" == "usage" ]] || fail "Wrong plugin name"
[[ "$(json_value '.skills' "$manifest")" == "./skills/" ]] || fail "Wrong plugin skills path"
[[ "$(json_value '.license' "$manifest")" == "MIT" ]] || fail "Plugin license must be MIT"
version="$(json_value '.version' "$manifest")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || fail "Invalid plugin semver: $version"
jq -e '
  (.author.name | type == "string" and length > 0) and
  (.interface.displayName | type == "string" and length > 0) and
  (.interface.shortDescription | type == "string" and length > 0) and
  (.interface.longDescription | type == "string" and length > 0) and
  (.interface.developerName | type == "string" and length > 0) and
  (.interface.defaultPrompt | type == "array" and length > 0 and length <= 3) and
  (all(.interface.defaultPrompt[]; type == "string" and length <= 128))
' "$manifest" >/dev/null

check_skill skills/codex-usage codex-usage '$codex-usage'
check_skill skills/codex-forecast codex-forecast '$codex-forecast'
check_skill skills/codex-credits codex-credits '$codex-credits'
check_skill skills/codex-keepalive codex-keepalive '$codex-keepalive'
check_skill plugins/usage/skills/check check '$usage:check'
check_skill plugins/usage/skills/forecast forecast '$usage:forecast'
check_skill plugins/usage/skills/credits credits '$usage:credits'
check_skill plugins/usage/skills/keepalive keepalive '$usage:keepalive'

grep -q '^policy:$' skills/codex-keepalive/agents/openai.yaml || fail "Standalone keepalive must declare invocation policy"
grep -q '^  allow_implicit_invocation: false$' skills/codex-keepalive/agents/openai.yaml || fail "Standalone keepalive must require explicit invocation"
grep -q '^  allow_implicit_invocation: true$' plugins/usage/skills/keepalive/agents/openai.yaml || fail "Plugin keepalive must be available in the default skill catalog"

for script in scripts/*.sh tests/*.sh skills/*/scripts/*.sh plugins/usage/skills/*/scripts/*.sh; do
  check_script "$script"
done

scripts/sync-variants.sh --check

if git diff --quiet && git diff --cached --quiet; then
  exact_tag="$(git tag --points-at HEAD | sed -n '/^v[0-9]/p' | head -n 1)"
  if [[ -n "$exact_tag" && "$exact_tag" != "v$version" ]]; then
    fail "Tag $exact_tag does not match plugin version $version"
  fi
fi

# Keep red-flag strings encoded so this checker does not match itself.
machine_path="$(printf '\057\150\157\155\145\057\145\155\151\154')"
old_marketplace="$(printf '\145\155\151\154\055\165\163\141\147\145')"
old_display="$(printf '\105\155\151\154\040\125\163\141\147\145')"
grep_output="$(mktemp)"
trap 'rm -f "$grep_output"' EXIT

set +e
rg -n --hidden -g '!.git/**' "$machine_path|$old_marketplace|$old_display" . >"$grep_output"
rg_status="$?"
set -e
case "$rg_status" in
  0)
    cat "$grep_output" >&2
    fail "Found machine-specific or obsolete marketplace strings."
    ;;
  1) ;;
  *) fail "Red-flag scan failed with status $rg_status" ;;
esac

echo "Package check passed."
