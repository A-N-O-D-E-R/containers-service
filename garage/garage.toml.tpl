metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
replication_factor = 1
db_engine = "lmdb"

rpc_bind_addr = "[::]:3901"
rpc_secret = "${GARAGE_RPC_SECRET}"

[s3_api]
api_bind_addr = "[::]:3900"
s3_region = "garage"
root_domain = "s3.anode.com"


