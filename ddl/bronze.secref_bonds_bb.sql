-- Drop & recreate Bloomberg Bronze table (strictly typed)
DROP TABLE IF EXISTS bronze.secref_bonds_bb;

CREATE TABLE bronze.secref_bonds_bb (
  -- lineage
  vendor                string,          -- will be 'bloomberg'
  dataset               string,          -- e.g., 'secref'
  file_date             date,            -- landing date from key
  source_bucket         string,
  source_key            string,
  load_ts               timestamp,
  ingest_id             string,

  -- identifiers
  isin                  string,
  cusip                 string,
  sedol                 string,
  bbg_figi              string,
  ticker                string,

  -- instrument attributes (strict types)
  issuer_name           string,
  instrument_type       string,          -- normalized code/value per dictionary
  currency              string,          -- ISO 4217
  day_count             string,          -- e.g., '30E/360','ACT/360'
  coupon_type           string,          -- 'FIXED','FLOAT','ZERO','STEP'
  coupon                decimal(8,4),
  face_value            decimal(18,4),

  issue_dt              date,
  maturity_dt           date,
  first_coupon_dt       date,

  callable              boolean,
  puttable              boolean,
  seniority             string,

  -- validation outputs inline
  is_valid              boolean,         -- TRUE if the row passed validations
  reason_code           string,          -- NULL when valid; else short code
  reason_detail         string           -- optional free-text (rule name/why)
)
PARTITIONED BY (file_date)
LOCATION 's3://<warehouse-bucket>/warehouse/bronze/secref_bonds_bb'
TBLPROPERTIES (
  'table_type'='ICEBERG',
  'format'='PARQUET',
  'format-version'='2',
  'write.parquet.compression-codec'='zstd'
);