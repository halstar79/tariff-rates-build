# =============================================================================
# One revision of the Budget Lab's tariff-rate-tracker per R process
# =============================================================================
# The tracker's full build assembles a ~210M-row daily panel (~50 GB in memory). Downstream use here needs only
# each revision's rate table, so this driver calls the tracker's own per-revision unit, build_revision_snapshot()
# (src/pipeline/revision_snapshot.R), unchanged, for ONE revision, and writes its rates to Parquet. A fresh process
# per revision releases all memory between revisions (peak ~10 GB). The tracker's rate logic is not modified.
#
#   Rscript a1_revision.R --tracker <clone> --out <dir> --list
#       real revisions with their effective dates (policy-effective dates, the tracker's default), CSV on stdout
#   Rscript a1_revision.R --tracker <clone> --out <dir> --boundaries
#       the synthetic bnd_<date> revisions (dates inside a real revision's interval where a Chapter 99 entry starts
#       or ends, plus the tracker's overrides), from discover_boundaries() on the HTS archives, CSV on stdout:
#       revision, date, owner_rev, source
#   Rscript a1_revision.R --tracker <clone> --out <dir> --revision 2026_rev_22
#       build one real revision -> <out>/rates_2026_rev_22.parquet and <out>/meta_2026_rev_22.csv
#   Rscript a1_revision.R --tracker <clone> --out <dir> --revision bnd_2026-07-31 --owner 2026_rev_13 --date 2026-07-31
#       build one boundary revision from its owner's archive
#
# Revision dates: the tracker's config/revision_dates.csv and its own logic (load_revision_dates with
# use_policy_dates = TRUE, not --use-hts-dates); never reimplemented here.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

args <- commandArgs(trailingOnly = TRUE)
opt <- function(name, default = NULL) {
  i <- match(paste0('--', name), args)
  if (is.na(i)) return(default)
  if (i == length(args) || startsWith(args[i + 1], '--')) return(TRUE)
  args[i + 1]
}
tracker <- normalizePath(path.expand(opt('tracker', '~/tariff/tariff-rate-tracker')))
out_dir <- path.expand(opt('out', '~/tariff/a1'))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out_dir <- normalizePath(out_dir)
work_dir <- file.path(out_dir, 'work')   # the tracker's per-revision caches (ch99_, products_); not published
dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)
setwd(tracker)                           # the tracker's here() and relative paths resolve from its root
suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
  library(here)
})
# exactly as src/pipeline/00_build_timeseries.R loads the per-revision build
source(here('src', 'core', 'module_loader.R'))
tariff_load_bundle('build', environment())

USE_POLICY_DATES <- TRUE
rev_dates <- load_revision_dates('config/revision_dates.csv', use_policy_dates = USE_POLICY_DATES)
pp_build <- load_policy_params(use_policy_dates = USE_POLICY_DATES)
census_codes_path <- 'resources/census_codes.csv'

if (isTRUE(opt('list'))) {
  write_csv(rev_dates %>% select(revision, effective_date), stdout())
  quit(status = 0)
}

if (isTRUE(opt('boundaries'))) {
  b <- discover_boundaries(rev_dates, snapshot_dir = work_dir, policy_params = pp_build,
                           overrides = pp_build$BOUNDARY_OVERRIDES, archive_dir = 'data/hts_archives')
  write_csv(b %>% transmute(revision, date, owner_rev, source), stdout())
  quit(status = 0)
}

rev_id <- opt('revision')
if (is.null(rev_id) || isTRUE(rev_id)) stop('give --list, --boundaries or --revision <id>')
owner <- opt('owner', rev_id)
eff_date <- if (!is.null(opt('date'))) as.Date(opt('date')) else {
  d <- rev_dates %>% filter(revision == rev_id)
  if (nrow(d) != 1) stop('revision not in revision_dates.csv: ', rev_id)
  d$effective_date
}
census_codes <- read_csv(census_codes_path, col_types = cols(.default = col_character()))
countries <- census_codes$Code
country_lookup <- build_country_lookup(census_codes_path)

t0 <- Sys.time()
res <- build_revision_snapshot(
  rev_id = rev_id, eff_date = eff_date, archive_rev_id = owner,
  archive_dir = 'data/hts_archives', output_dir = work_dir,
  country_lookup = country_lookup, countries = countries,
  census_codes = census_codes, pp_build = pp_build
)
unlink(res$snapshot_path)                # the .rds snapshot: the Parquet below replaces it
path <- file.path(out_dir, paste0('rates_', rev_id, '.parquet'))
tmp <- paste0(path, '.part')
arrow::write_parquet(res$rates, tmp, compression = 'zstd')
file.rename(tmp, path)
meta <- tibble(revision = rev_id, effective_date = as.character(eff_date), archive_rev_id = owner,
               rows = res$n_rates, seconds = round(as.numeric(difftime(Sys.time(), t0, units = 'secs'))),
               policy_dates = USE_POLICY_DATES,
               tracker_commit = system('git rev-parse HEAD', intern = TRUE))
write_csv(meta, file.path(out_dir, paste0('meta_', rev_id, '.csv')))
message('A1 ', rev_id, ': ', res$n_rates, ' rows -> ', path, ' (', meta$seconds, ' s)')
