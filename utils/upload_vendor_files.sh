BB=mdp-bb-raw-<acct>-<region>
REF=mdp-refinitiv-raw-<acct>-<region>

# Vendor files under date partitions
aws s3 cp bloomberg_secref_2025-09-23.csv.gz s3://$BB/dataset=secref/year=2025/month=09/day=23/bloomberg_secref_2025-09-23.csv.gz
aws s3 cp refinitiv_secref_2025-09-23.jsonl.gz s3://$REF/dataset=secref/year=2025/month=09/day=23/refinitiv_secref_2025-09-23.jsonl.gz

# Manifests (if you go manifest-driven triggers)
aws s3 cp manifest_bloomberg_secref_2025-09-23.json  s3://$BB/raw/_manifests/manifest_bloomberg_secref_2025-09-23.json
aws s3 cp manifest_refinitiv_secref_2025-09-23.json  s3://$REF/raw/_manifests/manifest_refinitiv_secref_2025-09-23.json