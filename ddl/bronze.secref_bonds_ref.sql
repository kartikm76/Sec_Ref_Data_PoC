DROP TABLE IF EXISTS bronze.secref_bonds_ref;

CREATE TABLE bronze.secref_bonds_ref (
  -- lineage
  vendor                string,          -- 'refinitiv'
  dataset               string,          -- 'secref'
  file_date             date,
  source_bucket         string,
  source_key            string,
  load_ts               timestamp,
  ingest_id             string,

  -- identifiers (rename to DataScope names if different)
  isin                  string,          -- REF: ISIN
  cusip                 string,          -- REF: CUSIP
  sedol                 string,          -- REF: SEDOL
  ric                   string,          -- REF: RIC (if provided)
  ticker                string,          -- REF: TICKER / TRDNG_SYMBL / issuer code
  bbg_figi              string,          -- REF: leave null if not provided

  -- attributes (types per dictionary; rename to match Refinitiv column names)
  issuer_name           string,          -- REF: ISSUER_NAME
  instrument_type       string,          -- REF: INSTRUMENT_TYPE / ASSET_CLASS
  currency              string,          -- REF: CURRENCY (ISO 4217)
  day_count             string,          -- REF: DAY_COUNT_CONVENTION
  coupon_type           string,          -- REF: COUPON_TYPE
  coupon                decimal(8,4),    -- REF: COUPON_RATE
  face_value            decimal(18,4),   -- REF: FACE_VALUE / PRINCIPAL

  issue_dt              date,            -- REF: ISSUE_DATE (format yyyy-MM-dd or per dict)
  maturity_dt           date,            -- REF: MATURITY_DATE
  first_coupon_dt       date,            -- REF: FIRST_COUPON_DATE

  callable              boolean,         -- REF: CALLABLE (Y/N/TRUE/FALSE)
  puttable              boolean,         -- REF: PUTTABLE  (Y/N/TRUE/FALSE)
  seniority             string,          -- REF: SENIORITY / RANK

  -- validation outputs inline
  is_valid              boolean,
  reason_code           string,
  reason_detail         string
)
PARTITIONED BY (file_date)
LOCATION 's3://<warehouse-bucket>/warehouse/bronze/secref_bonds_ref'
TBLPROPERTIES (
  'table_type'='ICEBERG',
  'format'='PARQUET',
  'format-version'='2',
  'write.parquet.compression-codec'='zstd'
);