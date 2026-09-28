#!/usr/bin/env python3
"""Union verified CSV batches: one header per table; dedupe shared references.

Usage: assemble.py <success_dir> <pending_dir> <out_dir>

Validates every selected batch BEFORE writing any output: directory names must
match ^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$, batch.json id/seed/population and file
inventory must check out, and files.sha256 must verify against the actual
regular CSV files. Tampered success/ data fails without deleting anything.
Reference tables (organizations/providers/payers) dedupe by Id; conflicting
duplicate Ids with differing fields fail instead of silently winning.
"""
import csv
import hashlib
import json
import re
import sys
from pathlib import Path

BATCH_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$")
REFERENCE_TABLES = {"organizations.csv", "providers.csv", "payers.csv"}


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
                                if key in ref_by_id and ref_by_id[key] != tuple(row):
                                    fail(f"conflicting {name} Id '{key}'")
                                if key in ref_by_id:
                                    continue
                                ref_by_id[key] = tuple(row)
                            w.writerow(row)
    except BaseException:
        for p in sorted(tmp.glob("*")):
            p.unlink()
        tmp.rmdir()
        raise
    tmp.rename(out)
    print(f"ASSEMBLED {len(tables)} tables from {len(selected)} batches")


if __name__ == "__main__":
    main()
