# =============================================================================
# Import weights keyed to the tip revision's product codes (the tracker's own code)
# =============================================================================
# The tracker publishes, with each vintage, an HS10 x country import-weight file whose hts10 keys are its current
# panel's codes: 2024 Census consumption imports, with value on retired statistical suffixes moved to their successors
# by its 484(f) transfer crosswalk (src/io/write_output.R -> build_panel_import_weights()). Budget Lab's Tariff-Model
# reads only that file. This script makes the same call, unchanged, with the tip revision taken from this
# repository's release instead of a published vintage directory.
#
# Before it, in the tracker's root (both downloads are Census's public monthly IMDB files):
#   Rscript src/io/build_import_weights.R --year 2024              -> data/weights/hs10_by_country_gtap_2024_con.rds
#   Rscript src/io/build_import_weights.R --year 2025 --no-gtap    -> data/weights/hs10_by_country_2025_con.rds
#
#   Rscript weights.R --tracker <clone> --release <dir with manifest.csv and the tip's rates parquet> --out <dir>
#       -> <out>/import_weights_hs10_country.parquet, hts10_revision_crosswalk.csv, weights_meta.csv

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

args <- commandArgs(trailingOnly = TRUE)
opt <- function(name, default = NULL) {
  i <- match(paste0('--', name), args)
  if (is.na(i) || i == length(args)) return(default)
  args[i + 1]
}
tracker <- normalizePath(path.expand(opt('tracker', '~/tariff/tariff-rate-tracker')))
release <- normalizePath(path.expand(opt('release', 'release')))
out_dir <- path.expand(opt('out', 'weights'))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out_dir <- normalizePath(out_dir)
setwd(tracker)
suppressPackageStartupMessages(library(here))
source(here('src', 'core', 'module_loader.R'))
source(here('src', 'io', 'build_panel_import_weights.R'))   # defines the functions; its CLI runs only as a script

# Tip = the latest interval start, as current_panel_codes() picks it from a published vintage. A boundary tip takes
# its owner archive's HTS identity, as write_output.R's resolve_tip_hts_as_of() does.
manifest <- read_csv(file.path(release, 'manifest.csv'), col_types = cols(.default = col_character()))
tip <- manifest %>% arrange(desc(as.Date(effective_date))) %>% slice(1)
codes <- arrow::read_parquet(file.path(release, tip$file), col_select = 'hts10')$hts10
panel_codes <- unique(as.character(codes))
hts_as_of <- .hts_identity_date(tip$archive_rev_id)
if (is.na(hts_as_of)) stop('no HTS identity date for ', tip$archive_rev_id)

base_path <- here('data', 'weights', 'hs10_by_country_gtap_2024_con.rds')
shares_path <- here('data', 'weights', 'hs10_by_country_2025_con.rds')
overrides_path <- here('resources', 'hts10_484f_overrides.csv')
for (p in c(base_path, shares_path)) if (!file.exists(p)) stop('missing ', p, ': run build_import_weights.R first')

res <- build_panel_import_weights(
  panel_codes    = panel_codes,
  base_path      = base_path,
  out_dir        = out_dir,
  year           = 2024L,
  hts_vintage    = tip$revision,
  method         = '484f',
  crosswalk_path = here('resources', 'hts10_484f_transfers.csv'),
  shares_path    = shares_path,
  overrides_path = if (file.exists(overrides_path)) overrides_path else NULL,
  hts_as_of_date = hts_as_of,
  write_csv      = FALSE
)

w <- arrow::read_parquet(file.path(out_dir, 'import_weights_hs10_country.parquet'))
base <- readRDS(base_path)
sha <- function(p) digest::digest(file = p, algo = 'sha256')
meta <- tibble(
  tip_revision = tip$revision, tip_effective_date = tip$effective_date, tip_archive = tip$archive_rev_id,
  hts_as_of_date = hts_as_of, panel_codes = length(panel_codes),
  rows = nrow(w), hts10 = n_distinct(w$hts10), countries = n_distinct(w$country),
  imports_total = sum(w$imports), base_imports_total = sum(base$imports),
  import_value_year = 2024L, shares_year = 2025L, method = '484f',
  base_sha256 = sha(base_path), shares_sha256 = sha(shares_path),
  tracker_commit = system('git rev-parse HEAD', intern = TRUE)
)
if (abs(meta$imports_total - meta$base_imports_total) > 1) stop('weights do not conserve the 2024 import total')
missing <- setdiff(unique(w$hts10), panel_codes)
if (length(missing)) stop(length(missing), ' weight codes are not in the tip panel')
write_csv(meta, file.path(out_dir, 'weights_meta.csv'))
message(sprintf('weights: %s rows, %s products, %s countries, $%.1fB (tip %s, HTS as of %s)',
                format(meta$rows, big.mark = ','), format(meta$hts10, big.mark = ','), meta$countries,
                meta$imports_total / 1e9, tip$revision, hts_as_of))
