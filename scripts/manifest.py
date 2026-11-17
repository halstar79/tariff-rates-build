"""Merge this run's builds into the release manifest and check the release is complete.

Inputs: required.csv (from plan.py), the release's current manifest.csv (if any), and a folder holding this run's
rates_<rev>.parquet, meta_<rev>.csv and peak_<rev>.txt files. Every required revision must end up with exactly one
manifest row: built now, or carried from the old manifest with its effective date and owner unchanged. Each new file's
meta must match its required row. Fails otherwise; nothing is published from a failed check.

Writes manifest.csv and orphans.txt (release files no longer required) into --out.
"""

import argparse
import csv
import hashlib
import sys
from pathlib import Path

FIELDS = ["revision", "kind", "effective_date", "archive_rev_id", "rows", "seconds", "peak_rss_mb",
          "policy_dates", "tracker_commit", "driver_hash", "file", "bytes", "sha256", "run_url"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def peak_mb(path):
    """Maximum resident set size from /usr/bin/time -v output, in MB."""
    if not path.exists():
        return ""
    for line in path.read_text().splitlines():
        if "Maximum resident set size" in line:
            return str(round(int(line.split(":")[-1]) / 1024))
    return ""


def merge(req, old, built_dir, driver_hash, tracker_commit, run_url):
    problems = []
    old_by = {m["revision"]: m for m in old}
    rows = []
    for r in req:
        rev = r["revision"]
        parquet = built_dir / f"rates_{rev}.parquet"
        if parquet.exists():
            meta_path = built_dir / f"meta_{rev}.csv"
            if not meta_path.exists():
                problems.append(f"{rev}: built file has no meta")
                continue
            meta = next(csv.DictReader(open(meta_path)))
            for field, want in (("revision", rev), ("effective_date", r["effective_date"]),
                                ("archive_rev_id", r["owner"]), ("tracker_commit", tracker_commit)):
                if meta[field] != want:
                    problems.append(f"{rev}: meta {field} {meta[field]!r}, expected {want!r}")
            if int(meta["rows"]) <= 0:
                problems.append(f"{rev}: no rate rows")
            rows.append({**{k: meta[k] for k in ("revision", "effective_date", "archive_rev_id", "rows",
                                                 "seconds", "policy_dates", "tracker_commit")},
                         "kind": r["kind"], "peak_rss_mb": peak_mb(built_dir / f"peak_{rev}.txt"),
                         "driver_hash": driver_hash, "file": parquet.name, "bytes": parquet.stat().st_size,
                         "sha256": sha256(parquet), "run_url": run_url})
        elif rev in old_by:
            m = old_by[rev]
            if (m["effective_date"], m["archive_rev_id"]) != (r["effective_date"], r["owner"]):
                problems.append(f"{rev}: release file is stale (date or owner changed) and was not rebuilt")
            if m["driver_hash"] != driver_hash or m["tracker_commit"] != tracker_commit:
                problems.append(f"{rev}: release file was built by another driver or tracker commit")
            rows.append(m)
        else:
            problems.append(f"{rev}: required but neither built now nor in the release")
    keep = {r["revision"] for r in req}
    orphans = sorted(m["file"] for m in old if m["revision"] not in keep)
    extra = sorted(p.name for p in built_dir.glob("rates_*.parquet")
                   if p.name[len("rates_"):-len(".parquet")] not in keep)
    if extra:
        problems.append(f"built files no revision requires: {extra}")
    rows.sort(key=lambda m: (m["effective_date"], m["revision"]))
    return rows, orphans, problems


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--required", required=True)
    p.add_argument("--old-manifest")
    p.add_argument("--built", required=True)
    p.add_argument("--driver-hash", required=True)
    p.add_argument("--tracker-commit", required=True)
    p.add_argument("--run-url", default="")
    p.add_argument("--out", required=True)
    a = p.parse_args(argv)

    req = list(csv.DictReader(open(a.required)))
    old = list(csv.DictReader(open(a.old_manifest))) if a.old_manifest and Path(a.old_manifest).exists() else []
    rows, orphans, problems = merge(req, old, Path(a.built), a.driver_hash, a.tracker_commit, a.run_url)
    for line in problems:
        print("PROBLEM", line, file=sys.stderr)
    if problems:
        raise SystemExit(f"{len(problems)} problems; nothing published")
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "manifest.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows({k: m.get(k, "") for k in FIELDS} for m in rows)
    (out / "orphans.txt").write_text("".join(o + "\n" for o in orphans))
    peaks = [int(m["peak_rss_mb"]) for m in rows if m.get("peak_rss_mb")]
    print(f"manifest: {len(rows)} revisions ({sum(m['kind'] == 'boundary' for m in rows)} boundary), "
          f"{sum(int(m['rows']) for m in rows):,} rate rows, peak memory max "
          f"{max(peaks) if peaks else 'n/a'} MB; {len(orphans)} orphans", file=sys.stderr)


if __name__ == "__main__":
    main()
