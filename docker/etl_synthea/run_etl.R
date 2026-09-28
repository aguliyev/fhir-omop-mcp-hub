# ETL-Synthea 2.1.1 load over the assembled snapshot (CDM 5.3, Synthea 3.3.0).
# Verified entry points, see ../PROVENANCE.md. Usage: run_etl.R <assembled_csv_dir>
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1) {
  stop("usage: run_etl.R <assembled_csv_dir>")
}
csv_dir <- args[[1]]

secret_lines <- readLines("/run/secrets/etl_password", warn = FALSE)
etl_pw <- paste(secret_lines, collapse = "")
if (nchar(etl_pw) == 0) {
  stop("empty /run/secrets/etl_password")
}

pg_host <- Sys.getenv("PGHOST", "postgres")
pg_port <- Sys.getenv("PGPORT", "5432")
pg_db <- Sys.getenv("PGDATABASE", "fhir_omop_mcp_hub")

cd <- DatabaseConnector::createConnectionDetails(
  dbms = "postgresql",
  server = paste0(pg_host, "/", pg_db),
  user = "etl_loader",
  password = etl_pw,
  port = pg_port,
  pathToDriver = "/opt/jdbc"
)
# Do NOT rm() the secret: DatabaseConnector captures connection arguments
# lazily and evaluates them in a separate thread at connect() time, so
# scrubbing etl_pw here breaks every connection with an evaluation error.
# The secret lives only in this one-shot container's memory.

cdm_schema <- "omop_csv"
staging_schema <- "omop_csv_temp"

ETLSyntheaBuilder::CreateSyntheaTables(
  connectionDetails = cd,
  syntheaSchema = staging_schema,
  syntheaVersion = "3.3.0"
)
ETLSyntheaBuilder::LoadSyntheaTables(
  connectionDetails = cd,
  syntheaSchema = staging_schema,
  syntheaFileLoc = csv_dir
)
ETLSyntheaBuilder::CreateMapAndRollupTables(
  connectionDetails = cd,
  cdmSchema = cdm_schema,
  syntheaSchema = staging_schema,
  cdmVersion = "5.3",
  syntheaVersion = "3.3.0"
)
ETLSyntheaBuilder::LoadEventTables(
  connectionDetails = cd,
  cdmSchema = cdm_schema,
  syntheaSchema = staging_schema,
  cdmVersion = "5.3",
  syntheaVersion = "3.3.0"
)
ETLSyntheaBuilder::DropSyntheaTables(
  connectionDetails = cd,
  syntheaSchema = staging_schema
)
writeLines("ETL_OK")
