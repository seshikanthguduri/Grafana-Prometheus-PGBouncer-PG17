#!/bin/bash
set -e

# Create the replication user account
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER replicator WITH REPLICATION PASSWORD 'replica_secure_password';
EOSQL

# Enable replication network security rules
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"

# Append synchronous configurations safely into the primary's runtime configuration file
echo "synchronous_commit = on" >> "$PGDATA/postgresql.conf"
echo "synchronous_standby_names = '*'" >> "$PGDATA/postgresql.conf"

