# tariff-rates-build

Builds the U.S. tariff rate tables of the Budget Lab at Yale's
[tariff-rate-tracker](https://github.com/Budget-Lab-Yale/tariff-rate-tracker) one revision at a time on GitHub
Actions, and publishes them as release files.

The tracker's own full build assembles a daily panel of every HTS product × country × day, about 210 million rows and
roughly 50 GB in memory. Many uses need only the rate table in force at each revision. This repository runs the
tracker's own per-revision function, `build_revision_snapshot()`, **unmodified**, in a fresh R process per revision
(peak memory about 10 GB, a few minutes each) and writes each revision's rates to Parquet.

**Nothing of the tracker is copied into this repository.** Each run fetches it at the commit pinned in
[`TRACKER_COMMIT`](TRACKER_COMMIT). The rate logic, revision dates, HTS archives and policy parameters are all the
tracker's. All credit for the rates belongs to the Budget Lab; errors in this packaging are ours.

## Output

One release per tracker commit and driver version, tagged `rates-<tracker commit>-d<driver hash>`:

- `rates_<revision>.parquet`: one row per HTS-10 product × Census country code, with the tracker's columns
  (`base_rate`, `rate_232`, `rate_301`, `rate_ieepa_recip`, `rate_ieepa_fent`, `rate_s122`, … `total_additional`,
  `total_rate`, `usmca_eligible`, metal shares and so on; rates are fractions, 0.1 = 10%). About 4.9 million rows and 6 MB
  per revision.
- `manifest.csv`: one row per revision: `kind` (`real` = a tracker revision; `boundary` = a date inside a revision's
  interval where a Chapter 99 entry starts or ends, or one of the tracker's configured policy dates, built from its
  owner revision's archive), `effective_date`, `archive_rev_id`, `rows`, build `seconds`, `peak_rss_mb`,
  `tracker_commit`, `driver_hash`, `bytes`, `sha256` and the run that built it.
- `LICENSE-tariff-rate-tracker.txt`: the tracker's MIT License, which covers these derived files.

Effective dates are the tracker's policy-effective dates (its default, not `--use-hts-dates`). A revision's rates apply
from its `effective_date` until the day before the next row's in `manifest.csv` (sorted by date). The `valid_from` and
`valid_until` columns inside the files are left empty by the tracker's per-revision step; use the manifest's dates.

Download with the GitHub CLI, for example `gh release download --repo halstar79/tariff-rates-build --pattern '*.parquet'`,
or from the release page.

## How a run works

[`.github/workflows/build.yml`](.github/workflows/build.yml):

1. **plan** lists the tracker's real revisions (`a1_revision.R --list`) and boundary revisions (`--boundaries`, the
   tracker's `discover_boundaries()` on its HTS archives), compares them with the release's manifest, and picks what to
   build: anything missing, anything whose date or owner archive changed, anything named in the run's inputs, or
   everything with `rebuild_all`.
2. **build** runs one job per revision, up to 20 at a time, each recording its peak memory.
3. **publish** checks that every required revision has exactly one file, that each new file's metadata matches the plan,
   and that no file is left over from a revision the tracker no longer lists (those are removed). Then it uploads.
   If any check fails, nothing is published.

Runs on a push that changes the pin, the driver or the workflow, weekly (boundary revisions can appear as time passes),
and by hand (Actions → Build tariff rates → Run workflow). A changed `TRACKER_COMMIT` or `a1_revision.R` gives a new
tag, so every revision is rebuilt into a new release; older releases stay as they were.

[`.github/workflows/upstream.yml`](.github/workflows/upstream.yml) opens an issue weekly when the tracker has commits
past the pinned one. Moving to them is a deliberate edit of `TRACKER_COMMIT` after reviewing the changes.

## Running locally

Needs R 4.6 with the tracker's packages (its `tools/install_dependencies.R`) plus `arrow`, on Linux or macOS
(boundary discovery forks), and about 12 GB of free memory:

```sh
git clone https://github.com/Budget-Lab-Yale/tariff-rate-tracker && git -C tariff-rate-tracker checkout "$(cat TRACKER_COMMIT)"
Rscript a1_revision.R --tracker tariff-rate-tracker --out out --list
Rscript a1_revision.R --tracker tariff-rate-tracker --out out --revision 2026_rev_22
Rscript a1_revision.R --tracker tariff-rate-tracker --out out --boundaries
Rscript a1_revision.R --tracker tariff-rate-tracker --out out --revision bnd_2026-07-31 --owner 2026_rev_13 --date 2026-07-31
```

## License

This repository's own files (the driver, scripts and workflows) are under the MIT License, [`LICENSE`](LICENSE). The
rate files are derived from tariff-rate-tracker and carry its MIT License, included with every release.
