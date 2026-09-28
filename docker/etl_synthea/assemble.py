#!/usr/bin/env python3
"""Union verified CSV batches: one header per table; dedupe shared references.

Usage: assemble.py <success_dir> <pending_dir> <out_dir>

Validates every selected batch BEFORE writing any output: directory names must
match ^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$, batch.json id/seed/population and file
inventory must check out, and files.sha256 must verify against the actual
regular CSV files. Tampered success/ data fails without deleting anything.
Reference tables (organizations/providers/payers) dedupe by Id; duplicate Ids
whose identity fields differ fail instead of silently winning. Synthea 3.3.0
regenerates per-run aggregate counters on reference rows (org REVENUE /
UTILIZATION, provider ENCOUNTERS / PROCEDURES, payer AMOUNT_* / REVENUE /
COVERED_* / MEMBER_MONTHS / ...); same Id with identical identity fields but
different counters is expected, not corruption, so those columns are excluded
from the identity comparison, the first row wins deterministically, and the
merge is reported. ETL-Synthea 2.1.1 R code never reads these columns, so
keeping one row is lossless.
"""
import csv
import hashlib
import json
import re
import sys
from pathlib import Path

BATCH_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$")
REFERENCE_TABLES = {"organizations.csv", "providers.csv", "payers.csv"}
# Per-batch aggregate counters, keyed by table. Only columns present in the
# header are ignored; anything else differing still fails.
AGGREGATE_COLUMNS = {
    "organizations.csv": {"REVENUE", "UTILIZATION"},
    "providers.csv": {"ENCOUNTERS", "PROCEDURES"},
    "payers.csv": {"AMOUNT_COVERED", "AMOUNT_UNCOVERED", "REVENUE",
                   "COVERED_ENCOUNTERS", "UNCOVERED_ENCOUNTERS",
                   "COVERED_MEDICATIONS", "UNCOVERED_MEDICATIONS",
                   "COVERED_PROCEDURES", "UNCOVERED_PROCEDURES",
                   "COVERED_IMMUNIZATIONS", "UNCOVERED_IMMUNIZATIONS",
                   "UNIQUE_CUSTOMERS", "QOLS_AVG", "MEMBER_MONTHS"},
}


def fail(msg):
    raise SystemExit(f"ASSEMBLE_FAILED: {msg}")


def load_batches(root):
    batches = []
    if not root.exists():
        return batches
    for batch in sorted(root.iterdir()):
        if not batch.is_dir() or batch.name.startswith("."):
            continue
        if not BATCH_RE.match(batch.name):
            fail(f"invalid batch id '{batch.name}'")
        manifest_path = batch / "batch.json"
        try:
            manifest = json.loads(manifest_path.read_text())
        except (OSError, ValueError) as e:
            fail(f"{batch.name}: unreadable batch.json ({e})")
        if manifest.get("batch_id") != batch.name:
            fail(f"{batch.name}: batch.json id mismatch")
        for key in ("seed", "population"):
            if not isinstance(manifest.get(key), int) or manifest[key] <= 0:
                fail(f"{batch.name}: bad {key} in batch.json")
        actual_csvs = sorted(
            p.name for p in batch.iterdir()
            if p.is_file() and not p.is_symlink() and p.suffix == ".csv"
        )
        if sorted(manifest.get("csv_files", [])) != actual_csvs:
            fail(f"{batch.name}: batch.json inventory != CSV files on disk")
        sha_path = batch / "files.sha256"
        try:
            lines = sha_path.read_text().splitlines()
        except OSError as e:
            fail(f"{batch.name}: unreadable files.sha256 ({e})")
        expected = {}
        for line in lines:
            parts = line.split()
            if len(parts) != 2:
                fail(f"{batch.name}: malformed files.sha256 line")
            expected[parts[1]] = parts[0]
        if sorted(expected) != actual_csvs:
            fail(f"{batch.name}: files.sha256 inventory != CSV files on disk")
        for name in actual_csvs:
            digest = hashlib.sha256((batch / name).read_bytes()).hexdigest()
            if digest != expected[name]:
                fail(f"{batch.name}: checksum mismatch for {name}")
        batches.append(batch)
    return batches


def main():
    success, pending, out = map(Path, sys.argv[1:4])
    selected = load_batches(success) + load_batches(pending)
    if not selected:
        fail("no batches selected")
    tables = {}
    for batch in selected:
        for f in sorted(batch.glob("*.csv")):
            tables.setdefault(f.name, []).append(f)
    tmp = out.parent / (out.name + ".tmp")
    if tmp.exists():
        fail(f"stale temp output {tmp} (manual recovery required)")
    tmp.mkdir(parents=True)
    try:
        merged = 0
        for name, files in sorted(tables.items()):
            header = None
            ref_by_id = {}
            with open(tmp / name, "w", newline="") as outf:
                w = None
                for f in files:
                    with open(f, newline="") as inf:
                        r = csv.reader(inf)
                        try:
                            h = next(r)
                        except StopIteration:
                            fail(f"empty file {f}")
                        if header is None:
                            header = h
                            w = csv.writer(outf)
                            w.writerow(header)
                        elif h != header:
                            fail(f"header mismatch in {f}")
                        id_idx = 0
                        if name in REFERENCE_TABLES and "Id" in header:
                            id_idx = header.index("Id")
                        for row in r:
                            if len(row) != len(header):
                                fail(f"ragged row in {f}")
                            if name in REFERENCE_TABLES:
                                key = row[id_idx]
                                ignore = {header.index(c) for c in AGGREGATE_COLUMNS.get(name, ()) if c in header}
                                ident = tuple(v for i, v in enumerate(row) if i not in ignore)
                                if key in ref_by_id:
                                    if ref_by_id[key] != ident:
                                        fail(f"conflicting {name} Id '{key}'")
                                    merged += 1
                                    continue
                                ref_by_id[key] = ident
                            w.writerow(row)
    except BaseException:
        for p in sorted(tmp.glob("*")):
            p.unlink()
        tmp.rmdir()
        raise
    tmp.rename(out)
    print(f"ASSEMBLED {len(tables)} tables from {len(selected)} batches ({merged} aggregate-only reference duplicates merged)")


if __name__ == "__main__":
    main()
