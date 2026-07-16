# Production Setup: PostgreSQL 17 Synchronous Replication with PgBouncer Pooling, Prometheus, and Grafana Monitoring

This document details the configuration for setting up a high-availability PostgreSQL 17 cluster utilizing synchronous replication, connection pooling via PgBouncer, and a monitoring stack consisting of Prometheus, Grafana, and dedicated metrics exporters.

---

## Architecture Overview

```text
                  +-----------------------+

                  |  Application / Client |
                  +-----------------------+
                              |
                     Port 6432 (Pooler)
                              v
                  +-----------------------+

                  |       PgBouncer       |
                  +-----------------------+
                     /                 \
     Port 5432 (Writes)               Port 5433 (Reads Only)
                   /                     \
                  v                       v
       +--------------------+   Sync   +--------------------+

       | PostgreSQL Primary | -------->| PostgreSQL Standby |
       |   (Read / Write)   |  Stream  |    (Read Only)     |
       +--------------------+          +--------------------+

                 |                                |
        +-----------------+              +-----------------+

        |   pg_exporter   |              | bouncer_exporter|
        |   (Port 9187)   |              |   (Port 9127)   |
        +-----------------+              +-----------------+
                 \                                /
                  \---->  [ Prometheus ]  <------/
                            (Port 9090)
                                 |
                          [   Grafana  ]
                            (Port 3000)
                                 |
                          [ Slack Alerts ]
```

- **PgBouncer** serves as the client gateway on port `6432`.
- Write traffic routes to `my_app_db_write` (Primary Node, port `54320` on host).
- Read traffic routes to `my_app_db_read` (Standby Node, port `54330` on host).
- **Primary** streams write operations synchronously to **Standby**. Transactions are only committed after the standby node acknowledges the write.
- **Prometheus** scrapes system states every 5 seconds, which are visualized in real-time via **Grafana**.

---

## 1. Project Directory Layout

Ensure your project workspace contains the following files:
```text
postgres-pgbouncer/
├── docker-compose.yml
├── pgbouncer.ini
├── userlist.txt
├── init-replication.sh
└── prometheus.yml
```

---

## 2. Configuration Files

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
    volumes:
      - pg_primary_data:/var/lib/postgresql/data
      - ./init-replication.sh:/docker-entrypoint-initdb.d/init-replication.sh:ro
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
          echo 'Cloning Primary Database State...'
          gosu postgres pg_basebackup -h pg_primary -D /var/lib/postgresql/data -U replicator -v -Fp -P -R -X stream
        fi

        echo 'Starting Standby Engine safely...'
        exec gosu postgres docker-entrypoint.sh postgres
    volumes:
      - pg_standby_data:/var/lib/postgresql/data
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
      - DATA_SOURCE_NAME=postgresql://db_user:your_secure_password@pg_primary:5432/my_app_db?sslmode=disable
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

# Create the dedicated streaming replication user
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER replicator WITH REPLICATION PASSWORD 'replica_secure_password';
EOSQL

# Add the authentication entry to pg_hba.conf
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"

# Append synchronous configuration rules
echo "synchronous_commit = on" >> "$PGDATA/postgresql.conf"
echo "synchronous_standby_names = '*'" >> "$PGDATA/postgresql.conf"
```
*Note: Run `chmod +x init-replication.sh` on your host terminal before initializing the cluster.*

### `pgbouncer.ini`
```ini
[databases]
my_app_db_write = host=pg_primary port=5432 dbname=my_app_db
my_app_db_read  = host=pg_standby port=5432 dbname=my_app_db

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
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

## 3. Deployment Steps

1. Clean up any existing volume and network states:
   ```bash
   docker compose down -v --remove-orphans
   ```

2. Boot the infrastructure stack in detached mode:
   ```bash
   docker compose up -d
   ```

3. Confirm that replication cloned and started smoothly on the standby instance:
   ```bash
   docker logs pg_standby
   ```
   *Expected end log:* `database system is ready to accept read-only connections`

---

## 4. Verification and Manual Monitoring

### Verify Synchronous Status and Replication Lag (Primary Node)
Connect directly to the primary node to check the write-ahead log receiver synchronization:
```bash
docker exec -it pg_primary psql -U db_user -d my_app_db -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"
```
*Verify that `sync_state` reads as **`sync`**.*

### Run Read / Write Operational Queries Through PgBouncer

#### Write Command Test:
```bash
docker exec -it pgbouncer_pool psql -h 127.0.0.1 -p 6432 -U db_user -d my_app_db_write -c "CREATE TABLE test_sync (id serial PRIMARY KEY, val text); INSERT INTO test_sync (val) VALUES ('synchronized');"
```

#### Read Command Test:
```bash
docker exec -it pgbouncer_pool psql -h 127.0.0.1 -p 6432 -U db_user -d my_app_db_read -c "SELECT * FROM test_sync;"
```

---

## 5. Grafana Dashboard and Alert Setup

1. Open your browser and navigate to **`http://localhost:3000`**.
2. Log in using `admin` / `admin_production_pass`.
3. Add a Data Source, choose **Prometheus**, specify the URL **`http://prometheus:9090`**, and click **Save & test**.
4. Go to **Dashboards -> New -> Import**:
   - Enter **`9628`** to load the community **PostgreSQL Dashboard**.
   - Enter **`14022`** to load the community **PgBouncer Dashboard**.
5. Head over to **Alerting -> Contact Points** to attach your incoming **Slack Webhook URL** for notification delivery on replication lag exceptions.
