"""Work out which revisions a run must build.

Required = the tracker's real revisions (a1_revision.R --list) plus its boundary revisions (--boundaries). A revision
is built when the release has no file for it, when its effective date or owner archive changed since it was built, when
named in --only, or for every revision with --rebuild-all. Release files no longer required are orphans: the publish
step removes them.

Writes <out>/required.csv (revision, kind, effective_date, owner) and <out>/matrix.json; prints GitHub outputs.
"""

import argparse
import csv
import io
import json
import os
import sys
from pathlib import Path


def read_csv_from(text, first_column):
    """CSV from a command's stdout, starting at its header line (anything printed before it is ignored)."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.split(",")[0].strip('"') == first_column:
            return list(csv.DictReader(io.StringIO("\n".join(lines[i:]))))
    raise SystemExit(f"no CSV header starting with {first_column!r} in the tracker's output")


def required(revisions, boundaries):
    rows = [{"revision": r["revision"], "kind": "real", "effective_date": r["effective_date"],
             "owner": r["revision"]} for r in revisions]
    rows += [{"revision": b["revision"], "kind": "boundary", "effective_date": b["date"],
              "owner": b["owner_rev"]} for b in boundaries]
    ids = [r["revision"] for r in rows]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        raise SystemExit(f"revision ids listed twice: {dupes}")
    real = {r["revision"] for r in revisions}
    bad_owner = [b["revision"] for b in boundaries if b["owner_rev"] not in real]
    if bad_owner:
        raise SystemExit(f"boundary revisions whose owner is not a real revision: {bad_owner}")
    return rows


def plan(req, manifest, assets, only=(), rebuild_all=False):
    """Revisions to build, and release files to remove."""
    built = {m["revision"]: m for m in manifest}
    unknown = sorted(set(only) - {r["revision"] for r in req})
    if unknown:
        raise SystemExit(f"--only names revisions the tracker does not list: {unknown}")
    todo = []
    for r in req:
        m = built.get(r["revision"])
        stale = (m is None or f"rates_{r['revision']}.parquet" not in assets
                 or m["effective_date"] != r["effective_date"] or m["archive_rev_id"] != r["owner"])
        if rebuild_all or stale or r["revision"] in only:
            todo.append(r)
    keep = {f"rates_{r['revision']}.parquet" for r in req}
    orphans = sorted(a for a in assets if a.startswith("rates_") and a.endswith(".parquet") and a not in keep)
    return todo, orphans


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--revisions", required=True, help="stdout of a1_revision.R --list")
    p.add_argument("--boundaries", required=True, help="stdout of a1_revision.R --boundaries")
    p.add_argument("--manifest", help="the release's manifest.csv, if the release exists")
    p.add_argument("--assets", help="file listing the release's asset names, one per line")
    p.add_argument("--only", default="", help="space-separated revisions to rebuild")
    p.add_argument("--rebuild-all", action="store_true")
    p.add_argument("--out", required=True)
    a = p.parse_args(argv)

    revs = read_csv_from(Path(a.revisions).read_text(), "revision")
    bnds = read_csv_from(Path(a.boundaries).read_text(), "revision")
    req = required(revs, bnds)
    manifest = list(csv.DictReader(open(a.manifest))) if a.manifest and Path(a.manifest).exists() else []
    assets = set(Path(a.assets).read_text().split()) if a.assets and Path(a.assets).exists() else set()
    todo, orphans = plan(req, manifest, assets, a.only.split(), a.rebuild_all)

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "required.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["revision", "kind", "effective_date", "owner"])
        w.writeheader()
        w.writerows(req)
    matrix = {"include": todo}
    (out / "matrix.json").write_text(json.dumps(matrix))

    print(f"{len(revs)} real + {len(bnds)} boundary revisions required; {len(todo)} to build; "
          f"{len(orphans)} orphaned files", file=sys.stderr)
    for r in todo:
        print(f"  build {r['revision']} ({r['kind']}, {r['effective_date']}, owner {r['owner']})", file=sys.stderr)
    for o in orphans:
        print(f"  orphan {o}", file=sys.stderr)
    gh = os.environ.get("GITHUB_OUTPUT")
    if gh:
        with open(gh, "a") as f:
            f.write(f"count={len(todo)}\norphans={len(orphans)}\nmatrix={json.dumps(matrix)}\n")


if __name__ == "__main__":
    main()
