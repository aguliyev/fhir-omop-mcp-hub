#!/bin/sh
# verify_manifest.sh STAGED_DIR — prove a staged Athena manifest.
#
# Verifies the 3-field manifest written by bin/stage-athena
# ("<sha256> <bytes> <basename>", sorted by basename): exactly the nine
# required files, no duplicates or extras, safe allow-listed basenames, and
# matching byte count plus SHA-256 per file. sha256sum -c cannot be used: it
# misparses the byte-count field as part of the filename and rejects every
# genuine manifest.
#
# Shared by db/athena/load.sh (container: "$SQL_DIR/verify_manifest.sh")
# and host wrappers (bin/load-vocab, bin/validate-vocab:
# "sh $REPO_ROOT/db/athena/verify_manifest.sh"). Single source of truth;
# POSIX sh so it runs under busybox ash, dash, and bash.
#
# Exit 0 iff the manifest proves the staged content. Silent on both paths
# (callers emit errors); never prints hashes, paths with data, or CSV rows.
set -eu

[ "$#" -eq 1 ] || { printf 'usage: verify_manifest.sh STAGED_DIR\n' >&2; exit 2; }
_dir="$1"
_manifest="$_dir/manifest.sha256"
[ -f "$_manifest" ] || exit 1
_seen=" "
_n=0
while IFS= read -r _line || [ -n "$_line" ]; do
  case "$_line" in ''|'#'*) continue ;; esac
  _sha="${_line%% *}"; _rest="${_line#* }"
  _bytes="${_rest%% *}"; _base="${_rest#* }"
  case "$_sha" in ''|*[!0-9a-f]*) exit 1 ;; esac
  [ "${#_sha}" -eq 64 ] || exit 1
  case "$_bytes" in ''|*[!0-9]*) exit 1 ;; esac
  case "$_base" in
    CONCEPT.csv|CONCEPT_ANCESTOR.csv|CONCEPT_CLASS.csv|CONCEPT_RELATIONSHIP.csv|CONCEPT_SYNONYM.csv|DOMAIN.csv|DRUG_STRENGTH.csv|RELATIONSHIP.csv|VOCABULARY.csv) ;;
    *) exit 1 ;;
  esac
  case "$_seen" in
    *" $_base "*) exit 1 ;;
  esac
  _seen="$_seen$_base "
  _f="$_dir/$_base"
  [ -f "$_f" ] && [ ! -L "$_f" ] || exit 1
  [ -s "$_f" ] || exit 1
  [ "$(wc -c <"$_f" | tr -d '[:space:]')" = "$_bytes" ] || exit 1
  [ "$(sha256sum "$_f" | awk '{print $1}')" = "$_sha" ] || exit 1
  _n=$((_n + 1))
done <"$_manifest"
[ "$_n" -eq 9 ]
