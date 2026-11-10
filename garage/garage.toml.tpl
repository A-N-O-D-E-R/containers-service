metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
replication_factor = 1
db_engine = "lmdb"
# consistent copies in meta/snapshots, picked up by scripts/backup.sh
metadata_auto_snapshot_interval = "6h"

rpc_bind_addr = "[::]:3901"
rpc_secret = "${GARAGE_RPC_SECRET}"

[s3_api]
api_bind_addr = "[::]:3900"
s3_region = "garage"
root_domain = "s3.anode.com"


