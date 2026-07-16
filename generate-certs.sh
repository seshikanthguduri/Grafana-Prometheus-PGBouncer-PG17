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
