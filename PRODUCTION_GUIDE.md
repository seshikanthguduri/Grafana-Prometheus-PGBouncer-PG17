# Production Guide: PostgreSQL 17 Synchronous Replication with PgBouncer Pooling, SSL/TLS, and Role Switchover

This production-grade document covers the complete configuration for an enterprise-ready PostgreSQL 17 cluster. It implements end-to-end SSL/TLS encryption, connection pooling via PgBouncer, Prometheus/Grafana infrastructure monitoring (using PgBouncer Dashboard `14022`), and an operational playbook for executing zero-data-loss manual switchovers.

---

## 1. Directory Structure

Ensure your local directory contains the following configuration files and scripts:
```text
postgres-pgbouncer/
├── docker-compose.yml
├── pgbouncer.ini
├── userlist.txt
├── init-replication.sh
├── prometheus.yml
└── generate-certs.sh
```

---

## 2. Automated SSL/TLS Setup

To prevent cleartext traffic across containers, we use a shell script that auto-generates a local Certificate Authority (CA) along with self-signed cryptographic certificates for both PostgreSQL and PgBouncer.

### `generate-certs.sh`
Create this script locally to automate the certificate pipeline:
```bash
#!/bin/bash
set -e

mkdir -p certs && cd certs

echo "Generating Certificate Authority (CA)..."
openssl req -new -x509 -days 3650 -nodes -text -out ca.crt -keyout ca.key \
  -subj "/CN=Database-Root-CA"

echo "Generating PostgreSQL Server Certificates..."
openssl req -new -nodes -text -out server.csr -keyout server.key \
  -subj "/CN=pg_primary"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365

echo "Generating PgBouncer Server Certificates..."
openssl req -new -nodes -text -out pgbouncer.csr -keyout pgbouncer.key \
  -subj "/CN=pgbouncer"
openssl x509 -req -in pgbouncer.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out pgbouncer.crt -days 365

# Secure key file permissions required by PostgreSQL
chmod 0600 *.key
chmod 0644 *.crt
echo "All SSL/TLS certificates generated successfully inside ./certs"
```
*Run `chmod +x generate-certs.sh && ./generate-certs.sh` on your host machine before building your containers.*

---

## 3. Production Configuration Files

### `docker-compose.yml`
```yaml
services:
  postgres_primary:
    image: postgres:17
    container_name: pg_primary
    environment:
      POSTGRES_USER: db_user
      POSTGRES_PASSWORD: your_secure_password
      POSTGRES_DB: my_app_db
    command: >
      postgres
      -c wal_level=replica
      -c max_wal_senders=10
      -c ssl=on
      -c ssl_cert_file=/etc/postgresql/certs/server.crt
      -c ssl_key_file=/etc/postgresql/certs/server.key
      -c ssl_ca_file=/etc/postgresql/certs/ca.crt
    volumes:
      - pg_primary_data:/var/lib/postgresql/data
      - ./init-replication.sh:/docker-entrypoint-initdb.d/init-replication.sh:ro
      - ./certs:/etc/postgresql/certs:ro
    networks:
      - db_network
    ports:
      - "54320:5432"

  postgres_standby:
    image: postgres:17
    container_name: pg_standby
    environment:
      PGPASSWORD: replica_secure_password
    entrypoint: [ "/bin/bash", "-c" ]
    command:
      - |
        echo "Checking primary node network availability..."
        until gosu postgres pg_isready -h pg_primary -p 5432; do
          echo "Primary is not ready yet. Retrying in 2 seconds..."
          sleep 2
        done

        if [ ! -s /var/lib/postgresql/data/PG_VERSION ]; then
          echo 'Cloning Primary Database State via SSL...'
          gosu postgres pg_basebackup -h pg_primary -D /var/lib/postgresql/data \
            -U replicator -v -Fp -P -R -X stream
        fi

        echo 'Starting Standby Engine safely...'
        exec gosu postgres docker-entrypoint.sh postgres \
          -c ssl=on \
          -c ssl_cert_file=/etc/postgresql/certs/server.crt \
          -c ssl_key_file=/etc/postgresql/certs/server.key \
          -c ssl_ca_file=/etc/postgresql/certs/ca.crt
    volumes:
      - pg_standby_data:/var/lib/postgresql/data
      - ./certs:/etc/postgresql/certs:ro
    networks:
      - db_network
    ports:
      - "54330:5432"
    depends_on:
      - postgres_primary

  pgbouncer:
    image: edoburu/pgbouncer:latest
    container_name: pgbouncer_pool
    environment:
      - LISTEN_PORT=6432
      - AUTH_TYPE=scram-sha-256
      - POOL_MODE=transaction
      - MAX_CLIENT_CONN=1000
      - DEFAULT_POOL_SIZE=20
      - ADMIN_USERS=db_user
    volumes:
      - ./userlist.txt:/etc/pgbouncer/userlist.txt:ro
      - ./pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ./certs:/etc/pgbouncer/certs:ro
    networks:
      - db_network
    ports:
      - "6432:6432"
    depends_on:
      - postgres_primary
      - postgres_standby

  postgres_exporter:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: pg_exporter
    environment:
      - DATA_SOURCE_NAME=postgresql://db_user:your_secure_password@pg_primary:5432/my_app_db?sslmode=require
    volumes:
      - ./certs:/etc/postgresql/certs:ro
    networks:
      - db_network
    depends_on:
      - postgres_primary

  pgbouncer_exporter:
    image: prometheuscommunity/pgbouncer-exporter:latest
    container_name: bouncer_exporter
    environment:
      - PGBOUNCER_EXPORTER_CONNECTION_STRING=postgresql://db_user:your_secure_password@pgbouncer:6432/pgbouncer?sslmode=disable
    networks:
      - db_network
    depends_on:
      - pgbouncer

  prometheus:
    image: prom/prometheus:latest
    container_name: monitoring_prometheus
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    networks:
      - db_network
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    container_name: monitoring_grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin_production_pass
    networks:
      - db_network
    ports:
      - "3000:3000"
    depends_on:
      - prometheus

volumes:
  pg_primary_data:
  pg_standby_data:

networks:
  db_network:
    driver: bridge
```

### `init-replication.sh`
```bash
#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER replicator WITH REPLICATION PASSWORD 'replica_secure_password';
EOSQL

# Restrict replication access to strict SSL/TLS parameters
echo "hostssl replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"

# Append production synchronous configurations
echo "synchronous_commit = on" >> "$PGDATA/postgresql.conf"
echo "synchronous_standby_names = '*'" >> "$PGDATA/postgresql.conf"
```
*Remember to execute `chmod +x init-replication.sh` on the host configuration folder.*

### `pgbouncer.ini`
```ini
[databases]
my_app_db_write = host=pg_primary port=5432 dbname=my_app_db server_tls_sslmode=require
my_app_db_read  = host=pg_standby port=5432 dbname=my_app_db server_tls_sslmode=require

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432

; Client-side SSL Settings
client_tls_sslmode = require
client_tls_key_file = /etc/pgbouncer/certs/pgbouncer.key
client_tls_cert_file = /etc/pgbouncer/certs/pgbouncer.crt

; Server-side Backend SSL Verification
server_tls_ca_file = /etc/pgbouncer/certs/ca.crt

auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=$1
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
admin_users = db_user
```

### `userlist.txt`
```text
"db_user" "your_secure_password"
```

### `prometheus.yml`
```yaml
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: 'postgresql'
    static_configs:
      - targets: ['postgres_exporter:9187']

  - job_name: 'pgbouncer'
    static_configs:
      - targets: ['pgbouncer_exporter:9127']
```

---

## 4. Initialization and Verification

1. Wipe any cached Docker configurations and spin up the complete environment stack:
   ```bash
   docker compose down -v --remove-orphans
   docker compose up -d
   ```

2. Confirm that the secure replication channel initialized successfully on the standby node:
   ```bash
   docker logs pg_standby
   ```

3. Open Grafana via **`http://localhost:3000`** (using credentials `admin` / `admin_production_pass`), map your Prometheus datasource to `http://prometheus:9090`, and import the monitoring interfaces:
   - **`9628`** (PostgreSQL Cluster Engine Dashboard)
   - **`14022`** (PgBouncer Pooling Performance Dashboard)

---

## 5. Playbook: Manual Graceful Switchover

Follow these sequential steps to safely reverse the cluster roles for planned hardware maintenance or rolling node updates without dropping in-flight data.

### Step 1: Pause PgBouncer Traffic
Freeze incoming application traffic requests to prevent transactions from occurring during the role transition:
```bash
docker exec -it pgbouncer_pool psql -h 127.0.0.1 -p 6432 -U db_user -d pgbouncer -c "PAUSE;"
```

### Step 2: Demote the Old Primary Node
Gracefully stop the old primary engine to ensure all outstanding write-ahead logs (WAL) flush completely over the wire to the standby:
```bash
docker compose stop postgres_primary
```

### Step 3: Promote the Standby Node to Primary
Instruct the standby database instance to break out of recovery mode and assume the primary master read/write identity:
```bash
docker exec -it pg_standby pg_ctl -D /var/lib/postgresql/data promote
```

### Step 4: Re-route PgBouncer Map Configuration
Open your local host pgbouncer.ini file and swap the backend routing hosts so my_app_db_write points directly to the newly promoted node:
```ini 
[databases] 
my_app_db_write = 
host=pg_standby 
port=5432 
dbname=my_app_db 
server_tls_sslmode=require 
my_app_db_read  = 
host=pg_primary port=5432 
dbname=my_app_db 
server_tls_sslmode=require 
```

### Step 5: Resume PgBouncer TrafficUnfreeze the pooler to instantly point client applications to the new topology layout with zero client disconnect failures:

```bash 
docker exec -it pgbouncer_pool psql -h 127.0.0.1 -p 6432 -U db_user -d pgbouncer -c "RELOAD;" docker exec -it pgbouncer_pool psql -h 127.0.0.1 -p 6432 -U db_user -d pgbouncer -c "RESUME;"
```
### Step 6: Convert the Old Primary into a Standby NodeTo bring the old primary engine back online as the new downstream tracking replica, initialize a pg_basebackup template from the new master source:
```bash 
# Clear old data files safely
docker compose run --entrypoint "" postgres_primary bash -c "rm -rf /var/lib/postgresql/data/*"

# Re-clone from the newly promoted database engine
docker compose run --entrypoint "" postgres_primary bash -c "PGPASSWORD=replica_secure_password pg_basebackup -h pg_standby -D /var/lib/postgresql/data -U replicator -v -Fp -P -R -X stream"

# Launch the container back into the cluster layout
docker compose start postgres_primary
```

The cluster roles are now fully reversed, maintaining total data consistency over verified SSL network pipelines.
***

