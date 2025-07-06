#!/bin/bash
set -e

echo "==> Update und Abhängigkeiten installieren"
apt-get update
apt-get install -y curl gnupg software-properties-common

echo "==> Loki installieren"
LOKI_VERSION="2.8.2"
curl -Lo /usr/local/bin/loki https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64
chmod +x /usr/local/bin/loki

echo "==> Loki Konfigurationsverzeichnis anlegen"
mkdir -p /etc/loki

cat > /etc/loki/local-config.yaml << EOF
auth_enabled: false

server:
  http_listen_port: 3100

ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
    final_sleep: 0s
  chunk_idle_period: 5m
  chunk_retain_period: 30s
  max_transfer_retries: 0

schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 168h

storage_config:
  boltdb_shipper:
    active_index_directory: /var/loki/index
    cache_location: /var/loki/cache
    shared_store: filesystem
  filesystem:
    directory: /var/loki/chunks

limits_config:
  enforce_metric_name: false
  reject_old_samples: true
  reject_old_samples_max_age: 168h

chunk_store_config:
  max_look_back_period: 0s

table_manager:
  retention_deletes_enabled: true
  retention_period: 720h
EOF

echo "==> Verzeichnisse für Loki anlegen"
mkdir -p /var/loki/index /var/loki/cache /var/loki/chunks
chown -R nobody:nogroup /var/loki

echo "==> Systemd Service für Loki anlegen"
cat > /etc/systemd/system/loki.service << EOF
[Unit]
Description=Loki Log Aggregation System
After=network.target

[Service]
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/local-config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "==> rsyslog installieren und konfigurieren"
apt-get install -y rsyslog

cat > /etc/rsyslog.d/10-loki.conf << EOF
module(load="imfile" PollingInterval="10")

input(type="imfile"
      File="/var/log/syslog"
      Tag="syslog"
      Severity="info"
      Facility="local7")

# Lokale Datei für Promtail
EOF

systemctl restart rsyslog

echo "==> Promtail installieren"
PROMTAIL_VERSION="2.8.2"
curl -Lo /usr/local/bin/promtail https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64
chmod +x /usr/local/bin/promtail

echo "==> Promtail Konfiguration erstellen"
mkdir -p /etc/promtail

cat > /etc/promtail/promtail.yaml << EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/log/promtail.positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push

scrape_configs:
  - job_name: syslog
    static_configs:
      - targets:
          - localhost
        labels:
          job: syslog
          __path__: /var/log/syslog
EOF

echo "==> Systemd Service für Promtail anlegen"
cat > /etc/systemd/system/promtail.service << EOF
[Unit]
Description=Promtail Log Collector
After=network.target

[Service]
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "==> Dienste starten und aktivieren"
systemctl daemon-reload
systemctl enable --now loki
systemctl enable --now promtail

echo "==> Fertig! Loki läuft auf Port 3100, Promtail auf 9080"
