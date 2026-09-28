#!/bin/sh
# stage-athena behavioral tests (Task 3). POSIX sh. Uses temp DATA_ROOT, no Docker.
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
STAGE="$REPO_ROOT/bin/stage-athena"
FIX="$REPO_ROOT/tests/setup/fixtures/athena-valid"

fail=0
ok() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
# Guard the shared ignored etc/setup.env: some prepare-data versions rewrite its
# DATA_ROOT line. Restore only when this test's own temp path leaked into it,
# so a concurrent worker's value is never clobbered.
setup_bak="$TMP/setup.env.bak"
cp "$REPO_ROOT/etc/setup.env" "$setup_bak" 2>/dev/null || true
restore_setup_env() {
  cur="$(awk -F= '/^DATA_ROOT=/{print $2}' "$REPO_ROOT/etc/setup.env" 2>/dev/null || true)"
  case "$cur" in
    "$TMP"*|"$REPO_ROOT") cp "$setup_bak" "$REPO_ROOT/etc/setup.env" 2>/dev/null || true ;;
  esac
}
trap 'restore_setup_env; rm -rf "$TMP"' EXIT
export DATA_ROOT="$TMP/data"

t=0
expect_ok() {
  t=$((t + 1)); desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
expect_fail_with() {
  t=$((t + 1)); desc="$1"; needle="$2"; shift 2
  out="$("$@" 2>&1 || true)"
  if printf '%s' "$out" | grep -F -q -- "$needle"; then ok "$desc"; else bad "$desc (missing '$needle' in: $out)"; fi
  if "$@" >/dev/null 2>&1; then bad "$desc (unexpected success)"; fail=1; else ok "$desc exits nonzero"; fi
}

cpdir() { rm -rf "$TMP/case"; mkdir -p "$TMP/case"; cp "$FIX"/*.csv "$TMP/case/"; printf '%s' "$TMP/case"; }

# 1. Valid nine-file directory succeeds.
D="$(cpdir)"
expect_ok "valid nine-file directory succeeds" "$STAGE" "$D"
[ -f "$DATA_ROOT/athena_input/current/manifest.sha256" ] && ok "manifest written" || bad "manifest written"
[ -f "$DATA_ROOT/athena_input/current/source.env" ] && ok "source.env written" || bad "source.env written"
rm -rf "$DATA_ROOT/athena_input"

# 2. Missing file fails by name.
D="$(cpdir)"; rm "$D/CONCEPT.csv"
expect_fail_with "missing CONCEPT.csv fails by name" "CONCEPT.csv" "$STAGE" "$D"
rm -rf "$DATA_ROOT/athena_input"

# 3. Empty file fails by name.
D="$(cpdir)"; : >"$D/DOMAIN.csv"
expect_fail_with "empty DOMAIN.csv fails by name" "DOMAIN.csv" "$STAGE" "$D"
rm -rf "$DATA_ROOT/athena_input"

# 4. Comma-delimited fails by name.
D="$(cpdir)"; tr '\t' ',' <"$FIX/RELATIONSHIP.csv" >"$D/RELATIONSHIP.csv"
expect_fail_with "comma-delimited RELATIONSHIP.csv fails by name" "RELATIONSHIP.csv" "$STAGE" "$D"
rm -rf "$DATA_ROOT/athena_input"

# 5. Wrong header fails by name.
D="$(cpdir)"; printf 'a\tb\tc\n1\t2\t3\n' >"$D/DRUG_STRENGTH.csv"
expect_fail_with "wrong-header DRUG_STRENGTH.csv fails by name" "DRUG_STRENGTH.csv" "$STAGE" "$D"
rm -rf "$DATA_ROOT/athena_input"

# 6. Duplicate basename in nested directories fails.
D="$(cpdir)"; mkdir -p "$D/nested"; cp "$FIX/CONCEPT.csv" "$D/nested/CONCEPT.csv"
expect_fail_with "duplicate basename fails" "CONCEPT.csv" "$STAGE" "$D"
rm -rf "$DATA_ROOT/athena_input"

# 7. Symlink input fails.
D="$(cpdir)"; rm "$D/CONCEPT.csv"; ln -s "$FIX/CONCEPT.csv" "$D/CONCEPT.csv"
expect_fail_with "symlink input fails" "CONCEPT.csv" "$STAGE" "$D"
rm -rf "$DATA_ROOT/athena_input"

# 8. SOURCE_TO_CONCEPT_MAP.csv is not required (absence and extra both OK).
D="$(cpdir)"
expect_ok "SOURCE_TO_CONCEPT_MAP.csv not required" "$STAGE" "$D"
rm -rf "$DATA_ROOT/athena_input"
D="$(cpdir)"; printf 'source_code\tsource_concept_id\nX\t1\n' >"$D/SOURCE_TO_CONCEPT_MAP.csv"
expect_ok "extra SOURCE_TO_CONCEPT_MAP.csv ignored" "$STAGE" "$D"

# 9. Replacement without --replace fails; with --replace moves current to previous.
D2="$(mktemp -d)"; cp "$FIX"/*.csv "$D2/"
printf '999\tStaged v2\tDrug\tRxNorm\tIngredient\tS\t999\t2020-01-01\t2099-12-31\t\n' >>"$D2/CONCEPT.csv"
if "$STAGE" "$D2" >/dev/null 2>&1; then bad "replacement without --replace fails"; else ok "replacement without --replace fails"; fi
expect_ok "confirmed replacement succeeds" "$STAGE" --replace "$D2"
[ -f "$DATA_ROOT/athena_input/previous/manifest.sha256" ] && ok "previous preserved" || bad "previous preserved"
[ -f "$DATA_ROOT/athena_input/current/manifest.sha256" ] && ok "current replaced" || bad "current replaced"
rm -rf "$D2"

# 10. Manifest contains SHA-256 and byte count for every CSV.
mok=1
while IFS= read -r base; do
  [ -n "$base" ] || continue
  line="$(grep -F -- " $base" "$DATA_ROOT/athena_input/current/manifest.sha256" || true)"
  sha="$(printf '%s' "$line" | awk '{print $1}')"
  bytes="$(printf '%s' "$line" | awk '{print $2}')"
  if [ "${#sha}" -ne 64 ] || ! printf '%s' "$bytes" | grep -q '^[0-9][0-9]*$'; then mok=0; fi
done <"$REPO_ROOT/etc/athena-required-files.txt"
[ "$mok" -eq 1 ] && ok "manifest has SHA-256 and byte count per CSV" || bad "manifest has SHA-256 and byte count per CSV"

# 11. Staged state is ignored by Git.
if git -C "$REPO_ROOT" check-ignore -q "data/athena_input/current/CONCEPT.csv" 2>/dev/null; then
  ok "staged state ignored by git"
else
  bad "staged state ignored by git"
fi

# 12. Fixture vocabularies cover required families.
for v in CVX LOINC RxNorm SNOMED UCUM; do
  if grep -q -- "$v" "$FIX/VOCABULARY.csv"; then ok "fixture has $v"; else bad "fixture has $v"; fi
done

# 13. Staged flow after prepare-data: first stage needs no --replace (H1).
rm -rf "$DATA_ROOT/athena_input"
"$REPO_ROOT/bin/prepare-data" >/dev/null
[ -d "$DATA_ROOT/athena_input/current" ] && bad "prepare-data leaves current to stage-athena" || ok "prepare-data leaves current to stage-athena"
D="$(cpdir)"
expect_ok "first stage after prepare-data needs no --replace" "$STAGE" "$D"

# 14. Empty current dir is not prior state (H1 hardening).
rm -rf "$DATA_ROOT/athena_input"; mkdir -p "$DATA_ROOT/athena_input/current"
D="$(cpdir)"
expect_ok "empty current needs no --replace" "$STAGE" "$D"

# 15. Empty previous never nests current inside it (H2).
rm -rf "$DATA_ROOT/athena_input"; mkdir -p "$DATA_ROOT/athena_input/previous"
D="$(cpdir)"
expect_ok "stage with empty previous and no current succeeds" "$STAGE" "$D"
D2="$(mktemp -d)"; cp "$FIX"/*.csv "$D2/"
printf '1000\tStaged v3\tDrug\tRxNorm\tIngredient\tS\t1000\t2021-01-01\t2099-12-31\t\n' >>"$D2/CONCEPT.csv"
expect_ok "replace with empty previous succeeds" "$STAGE" --replace "$D2"
[ -f "$DATA_ROOT/athena_input/previous/manifest.sha256" ] && ok "previous holds manifest file" || bad "previous holds manifest file"
[ -e "$DATA_ROOT/athena_input/previous/current" ] && bad "no previous/current nesting" || ok "no previous/current nesting"
if [ "$(cat "$DATA_ROOT/athena_input/current/manifest.sha256")" != "$(cat "$DATA_ROOT/athena_input/previous/manifest.sha256")" ]; then
  ok "previous holds old, current holds new"
else
  bad "previous holds old, current holds new"
fi
rm -rf "$D2"

# 16. Non-empty previous requires YES confirmation (H2 guard).
D3="$(mktemp -d)"; cp "$FIX"/*.csv "$D3/"
printf '1001\tStaged v4\tDrug\tRxNorm\tIngredient\tS\t1001\t2022-01-01\t2099-12-31\t\n' >>"$D3/CONCEPT.csv"
if printf 'no\n' | "$STAGE" --replace "$D3" >/dev/null 2>&1; then bad "previous replacement without YES fails"; else ok "previous replacement without YES fails"; fi
if printf 'YES\n' | "$STAGE" --replace "$D3" >/dev/null 2>&1; then ok "previous replacement with YES succeeds"; else bad "previous replacement with YES succeeds"; fi
rm -rf "$D3"

# 17. Sneaky DATA_ROOT resolving to the repo root is rejected with no repo pollution (H3).
poll=""
for d in postgres secrets athena_input work csv_input fhir_input .fhir_omop_mcp_hub_data_root data-probe-sneaky; do
  [ -e "$REPO_ROOT/$d" ] || poll="$poll $d"
done
SNEAKY="$REPO_ROOT/data-probe-sneaky/.."
if DATA_ROOT="$SNEAKY" "$REPO_ROOT/bin/prepare-data" >/dev/null 2>&1; then bad "sneaky DATA_ROOT rejected"; else ok "sneaky DATA_ROOT rejected"; fi
[ -e "$REPO_ROOT/data-probe-sneaky" ] && bad "no repo pollution" || ok "no repo pollution"
ln -s "$REPO_ROOT" "$TMP/repolink"
if DATA_ROOT="$TMP/repolink" "$REPO_ROOT/bin/prepare-data" >/dev/null 2>&1; then bad "symlinked repo DATA_ROOT rejected"; else ok "symlinked repo DATA_ROOT rejected"; fi
[ -e "$REPO_ROOT/.fhir_omop_mcp_hub_data_root" ] && bad "no sentinel in repo root" || ok "no sentinel in repo root"
rm -f "$TMP/repolink"
for d in $poll; do rm -rf "$REPO_ROOT/$d"; done
restore_setup_env

# 18. Env-override DATA_ROOT must not leak into ignored etc/setup.env (M2).
M2D="$TMP/m2data"
DATA_ROOT="$M2D" "$REPO_ROOT/bin/prepare-data" >/dev/null
if grep -F -q -- "$M2D" "$REPO_ROOT/etc/setup.env" 2>/dev/null; then bad "env DATA_ROOT stays out of etc/setup.env"; else ok "env DATA_ROOT stays out of etc/setup.env"; fi
restore_setup_env

# 19. Mismatched sentinel refuses without clobbering.
SD="$TMP/sentdata"; mkdir -p "$SD"; printf 'other-tool\n' >"$SD/.fhir_omop_mcp_hub_data_root"
if DATA_ROOT="$SD" "$REPO_ROOT/bin/prepare-data" >/dev/null 2>&1; then bad "mismatched sentinel refused"; else ok "mismatched sentinel refused"; fi
[ "$(cat "$SD/.fhir_omop_mcp_hub_data_root")" = "other-tool" ] && ok "sentinel not clobbered" || bad "sentinel not clobbered"

# 20. Sentinel accepts exact bytes or one trailing newline, rejects foreign (L5b).
# The 17-byte no-newline form is what lifecycle stubs write; plan treats the
# newline as non-essential, and a valid file must never be rewritten.
S1="$TMP/sen1"; mkdir -p "$S1"; printf 'fhir_omop_mcp_hub' >"$S1/.fhir_omop_mcp_hub_data_root"
if DATA_ROOT="$S1" "$REPO_ROOT/bin/prepare-data" >/dev/null 2>&1; then ok "no-newline sentinel accepted"; else bad "no-newline sentinel accepted"; fi
[ "$(wc -c <"$S1/.fhir_omop_mcp_hub_data_root" | tr -d ' ')" = "17" ] && ok "valid sentinel file untouched" || bad "valid sentinel file untouched"
S2="$TMP/sen2"; mkdir -p "$S2"; printf 'fhir_omop_mcp_hub\n' >"$S2/.fhir_omop_mcp_hub_data_root"
if DATA_ROOT="$S2" "$REPO_ROOT/bin/prepare-data" >/dev/null 2>&1; then ok "newline sentinel accepted"; else bad "newline sentinel accepted"; fi

# 21. Equivalent Athena text encodings must not fail header/row validation.
rm -rf "$DATA_ROOT/athena_input"
D="$(cpdir)"; awk '{printf "%s\r\n", $0}' "$FIX/CONCEPT.csv" >"$D/CONCEPT.csv"
expect_ok "CRLF header accepted" "$STAGE" "$D"
rm -rf "$DATA_ROOT/athena_input"
D="$(cpdir)"; { printf '\357\273\277'; cat "$FIX/CONCEPT.csv"; } >"$D/CONCEPT.csv"
expect_ok "UTF-8 BOM header accepted" "$STAGE" "$D"
rm -rf "$DATA_ROOT/athena_input"
D="$(cpdir)"; awk 'NR == 1 { print; next } { printf "%s", $0 }' "$FIX/CONCEPT.csv" >"$D/CONCEPT.csv"
expect_ok "last data row without newline accepted" "$STAGE" "$D"

export DATA_ROOT="$TMP/data"

if [ "$fail" -ne 0 ]; then printf 'stage-athena: FAILED\n'; exit 1; fi
printf 'stage-athena: PASSED\n'
