#!/bin/sh
# Behavioral contract test for the setup-fhir-omop-mcp-hub skill (Task 6).
# Structural assertions over skill behavior: frontmatter shape, exit-code
# semantics, readiness gating, outcome definitions, reference completeness,
# and privacy (no leaked user paths). Exact-string checks remain only where
# the plan pins exact wording.
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$REPO_ROOT/.agents/skills/setup-fhir-omop-mcp-hub"
SKILL="$SKILL_DIR/SKILL.md"
REF="$SKILL_DIR/references/athena-download.md"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fail_msg() { printf 'FAIL: %s\n' "$1"; fail=1; }
assert() {
  desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail_msg "$desc"; fi
}
assert_contains() {
  file="$1"; desc="$2"; pattern="$3"
  if [ ! -f "$file" ]; then fail_msg "$desc (missing $file)"; return; fi
  if grep -F -q -- "$pattern" "$file"; then pass "$desc"; else fail_msg "$desc"; fi
}
# Two concepts must be documented together (same step), not merely co-mentioned.
assert_proximity() {
  file="$1"; desc="$2"; pat1="$3"; pat2="$4"; max="$5"
  if [ ! -f "$file" ]; then fail_msg "$desc (missing $file)"; return; fi
  lines1="$(grep -n -F -- "$pat1" "$file" | cut -d: -f1)"
  lines2="$(grep -n -F -- "$pat2" "$file" | cut -d: -f1)"
  if [ -z "$lines1" ] || [ -z "$lines2" ]; then fail_msg "$desc"; return; fi
  for a in $lines1; do
    for b in $lines2; do
      d=$((a > b ? a - b : b - a))
      if [ "$d" -le "$max" ]; then pass "$desc"; return; fi
    done
  done
  fail_msg "$desc"
}
assert_line_matches() {
  file="$1"; desc="$2"; pattern="$3"
  if [ ! -f "$file" ]; then fail_msg "$desc (missing $file)"; return; fi
  if grep -E -q -- "$pattern" "$file"; then pass "$desc"; else fail_msg "$desc"; fi
}

EXPECTED_DESC="Bootstrap or verify this repository's local Docker, PostgreSQL, and OHDSI Athena vocabulary prerequisite before ingestion or FhirToCdm spikes. Use when asked to set up the project, prepare Athena, resume after a vocabulary download, or diagnose setup readiness."

# --- Package shape ---
assert "skill entrypoint exists" test -f "$SKILL"
assert "athena reference exists" test -f "$REF"
assert "test itself is executable" test -x "$0"
assert "skill reference link resolves to a real file" sh -c 'test -f "$1/$(grep -o -E -- "references/[A-Za-z0-9_./-]+\.md" "$1/SKILL.md" | head -n 1)"' _ "$SKILL_DIR"

# --- Frontmatter structure (not just string presence) ---
assert "frontmatter opens with ---" sh -c "head -n 1 \"\$1\" | grep -qx -- '---'" _ "$SKILL"
CLOSE="$(awk 'NR>1 && $0=="---" {print NR; exit}' "$SKILL")"
assert "frontmatter has a closing --- near the top" sh -c 'test -n "$1" && test "$1" -le 10' _ "$CLOSE"
assert "frontmatter holds exactly name + description keys" sh -c 'test "$(sed -n "2,$(( $1 - 1 ))p" "$2" | grep -c -E -- "^(name|description): ")" -eq 2' _ "$CLOSE" "$SKILL"
assert_line_matches "$SKILL" "skill name uses only lowercase letters, digits, hyphens" "^name: [a-z0-9-]+$"
assert "skill name matches its directory" sh -c 'test "$(sed -n "s/^name: //p" "$1")" = "$(basename "$(dirname "$1")")"' _ "$SKILL"
assert_line_matches "$SKILL" "description carries a Use-when trigger clause" "^description: .*Use when"
assert "frontmatter stays within the 1024-char budget" sh -c 'test "$(head -n "$1" "$2" | wc -c)" -le 1024' _ "$CLOSE" "$SKILL"
assert_contains "$SKILL" "exact skill name" "name: setup-fhir-omop-mcp-hub"
assert_contains "$SKILL" "exact skill description" "$EXPECTED_DESC"

# --- Exit-code semantics: code, token, and human action documented together ---
assert_proximity "$SKILL" "exit 20 pauses with ATHENA_REQUIRED for the download" "20" "ATHENA_REQUIRED" 3
assert_proximity "$SKILL" "ATHENA_REQUIRED pause routes to the official site" "ATHENA_REQUIRED" "https://athena.ohdsi.org/" 5
assert_proximity "$SKILL" "exit 21 pauses with ATHENA_REPLACE_APPROVAL_REQUIRED" "21" "ATHENA_REPLACE_APPROVAL_REQUIRED" 3
assert_proximity "$SKILL" "--replace is gated on explicit approval" "--replace" "approval" 5
assert_proximity "$SKILL" "current and staged versions shown before approval" "version" "approval" 5
assert_proximity "$SKILL" "preflight runs before any mutation" "bin/check-prerequisites" "before" 3
assert_proximity "$SKILL" "bin/setup used instead of duplicated logic" "bin/setup" "duplicating setup logic" 2
assert_proximity "$SKILL" "stage-athena waits for the user-supplied path" "bin/stage-athena" "only after the user responds" 2
assert_line_matches "$SKILL" "spike is handed off, never started here" "FhirToCdm.*do not start|do not start.*FhirToCdm"

# --- Readiness gate and outcome definitions ---
assert_line_matches "$SKILL" "READY is gated on bin/validate-setup passing" "READY.*bin/validate-setup|bin/validate-setup.*READY"
assert "all three outcomes BLOCKED/FAILED/READY are defined" sh -c 'test "$(grep -c -E -- "^[-*] \`(BLOCKED|FAILED|READY)\`:" "$1")" -eq 3' _ "$SKILL"
assert_proximity "$SKILL" "BLOCKED covers waiting on external prerequisites" "BLOCKED" "waiting for" 2
assert_proximity "$SKILL" "FAILED covers invalid input or partial state" "FAILED" "partial state" 2

# --- Privacy: user paths must not leak into tracked files ---
assert "no user export path copied into skill or reference" sh -c '! grep -E -q -- "/(home|Users|tmp)/|/absolute/path/provided|\\\\" "$1" "$2"' _ "$SKILL" "$REF"
assert_proximity "$SKILL" "skill warns against tracking the export path" "tracked files" "path" 3

# --- Reference completeness (counts, not one assert per string) ---
assert "reference lists all nine expected CSVs" sh -c 'n=0; for f in CONCEPT.csv CONCEPT_ANCESTOR.csv CONCEPT_CLASS.csv CONCEPT_RELATIONSHIP.csv CONCEPT_SYNONYM.csv DOMAIN.csv DRUG_STRENGTH.csv RELATIONSHIP.csv VOCABULARY.csv; do grep -F -q -- "$f" "$1" && n=$((n+1)); done; test "$n" -eq 9' _ "$REF"
assert "reference names all five required vocabularies" sh -c 'n=0; for v in SNOMED RxNorm LOINC CVX UCUM; do grep -F -q -- "$v" "$1" && n=$((n+1)); done; test "$n" -eq 5' _ "$SKILL"
assert "reference gives all six manual steps" sh -c 'test "$(grep -c -E -- "^[1-6]\\. " "$1")" -eq 6' _ "$REF"
assert_contains "$REF" "reference links official Athena site" "https://athena.ohdsi.org/"
assert_contains "$REF" "reference notes tab-delimited despite .csv" "tab-delimited"
assert_contains "$REF" "reference explains SOURCE_TO_CONCEPT_MAP.csv" "SOURCE_TO_CONCEPT_MAP.csv"
assert_proximity "$SKILL" "never automate license acceptance or take credentials" "never automate" "credentials" 3

if [ "$fail" -ne 0 ]; then
  printf 'setup skill contract: FAILED\n'
  exit 1
fi
printf 'setup skill contract: PASSED\n'
