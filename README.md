# ELK + Kafka Cluster on GCP — Deployment Guide

## Architecture

| Node | Internal IP | Services |
|------|-------------|----------|
| elk-node1 | 192.168.1.101 | Elasticsearch (master+data), Zookeeper, Kafka Broker 1 |
| elk-node2 | 192.168.1.102 | Elasticsearch (data), Zookeeper, Kafka Broker 2, Logstash |
| elk-node3 | 192.168.1.103 | Elasticsearch (data), Zookeeper, Kafka Broker 3, Kibana |

- **OS:** Rocky Linux 9
- **VM type:** e2-medium (2 vCPU, 4 GB RAM) — suitable for dev/test
- **Disk:** 60 GB pd-ssd per node
- **Region:** asia-south1 (Mumbai)
- **Network:** Custom VPC `elk-kafka-vpc`, subnet `192.168.1.0/24`

---

## Prerequisites

### 1. Install Terraform (Mac)

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform version   # should be >= 1.3
```

### 2. Install and configure gcloud (Mac)

```bash
# Install
brew install --cask google-cloud-sdk

# Login
gcloud auth login
gcloud auth application-default login

# Set your project
gcloud config set project YOUR_PROJECT_ID

# Verify
gcloud config list
```

### 3. Enable required GCP APIs

```bash
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
```

---

## Phase 1 — Terraform Deploy

### Configure variables

Create a `terraform.tfvars` file in the `elk-terraform/` directory:

```hcl
project_id = "your-gcp-project-id"

# Optional overrides (defaults are fine for dev/test):
# region              = "asia-south1"
# zone                = "asia-south1-a"
# machine_type        = "e2-medium"
# disk_size           = 60
# cluster_name        = "elk-cluster"
# es_heap_size        = "1g"
# logstash_heap_size  = "512m"
# kafka_version       = "3.7.0"
# kafka_scala_version = "2.13"
```

### Deploy

```bash
cd elk-terraform/

terraform init
terraform plan
terraform apply
```

Terraform will output SSH commands, the Kibana URL, and helper commands for each phase.

### Wait for startup scripts to complete

The startup scripts run automatically on first boot and take **8–12 minutes** to complete (installing Java, Kafka, Elasticsearch, etc.).

Monitor progress on each node from your Mac:

```bash
gcloud compute ssh elk-node1 --zone=asia-south1-a -- 'sudo tail -f /var/log/elk-startup.log'
gcloud compute ssh elk-node2 --zone=asia-south1-a -- 'sudo tail -f /var/log/elk-startup.log'
gcloud compute ssh elk-node3 --zone=asia-south1-a -- 'sudo tail -f /var/log/elk-startup.log'
```

Wait until you see `base setup COMPLETE` in all 3 logs before proceeding.

---

## Phase 2 — TLS Certificate Setup

Elasticsearch uses **transport TLS** between nodes. HTTP (port 9200) is plain HTTP — no HTTP SSL is configured. All steps below run as the `sj` user with `sudo`.

### Step 2a — Generate TLS certificates (elk-node1 only)

```bash
gcloud compute ssh elk-node1 --zone=asia-south1-a
```

```bash
# Generate Certificate Authority (CA) with empty password
sudo /usr/share/elasticsearch/bin/elasticsearch-certutil ca \
  --out /tmp/elastic-stack-ca.p12 --pass ""

# Generate node certificate signed by the CA (empty password)
sudo /usr/share/elasticsearch/bin/elasticsearch-certutil cert \
  --ca /tmp/elastic-stack-ca.p12 --ca-pass "" \
  --out /tmp/elastic-certificates.p12 --pass ""

# Install cert on node1
sudo mkdir -p /etc/elasticsearch/certs
sudo cp /tmp/elastic-certificates.p12 /etc/elasticsearch/certs/
sudo chown -R elasticsearch:elasticsearch /etc/elasticsearch/certs
sudo chmod 640 /etc/elasticsearch/certs/elastic-certificates.p12

# Make a readable copy in /tmp for scp (cert is owned by elasticsearch user)
sudo chmod 644 /tmp/elastic-certificates.p12
```

### Step 2b — Configure keystore (elk-node1 only)

> **Important:** Elasticsearch 8.x auto-populates `http.ssl` keystore entries during installation. These must be removed, otherwise ES fails to start with: `http.ssl.keystore.secure_password set but http.ssl.enabled not configured`.

```bash
# Clear any auto-added SSL keystore entries
for key in $(sudo /usr/share/elasticsearch/bin/elasticsearch-keystore list | grep ssl); do
  sudo /usr/share/elasticsearch/bin/elasticsearch-keystore remove "$key" 2>/dev/null || true
done

# Verify only non-ssl entries remain:
sudo /usr/share/elasticsearch/bin/elasticsearch-keystore list

# Add transport SSL passwords — press Enter (empty password) when prompted
sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add \
  xpack.security.transport.ssl.keystore.secure_password

sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add \
  xpack.security.transport.ssl.truststore.secure_password
```

### Step 2c — Copy cert to elk-node2 and elk-node3 (from your Mac)

```bash
# Pull cert from node1
gcloud compute scp elk-node1:/tmp/elastic-certificates.p12 /tmp/ --zone=asia-south1-a

# Push to node2 and node3
gcloud compute scp /tmp/elastic-certificates.p12 elk-node2:/tmp/ --zone=asia-south1-a
gcloud compute scp /tmp/elastic-certificates.p12 elk-node3:/tmp/ --zone=asia-south1-a
```

### Step 2d — Install cert + configure keystore (elk-node2 and elk-node3)

Run the following on **elk-node2**, then repeat identically on **elk-node3**:

```bash
gcloud compute ssh elk-node2 --zone=asia-south1-a   # or elk-node3
```

```bash
sudo mkdir -p /etc/elasticsearch/certs
sudo cp /tmp/elastic-certificates.p12 /etc/elasticsearch/certs/
sudo chown -R elasticsearch:elasticsearch /etc/elasticsearch/certs
sudo chmod 640 /etc/elasticsearch/certs/elastic-certificates.p12

# Clear auto-added SSL keystore entries
for key in $(sudo /usr/share/elasticsearch/bin/elasticsearch-keystore list | grep ssl); do
  sudo /usr/share/elasticsearch/bin/elasticsearch-keystore remove "$key" 2>/dev/null || true
done

# Add transport SSL passwords (press Enter for empty password)
sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add \
  xpack.security.transport.ssl.keystore.secure_password

sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add \
  xpack.security.transport.ssl.truststore.secure_password
```

### Step 2e — Start Elasticsearch (order matters!)

Start **elk-node1 first**, wait ~30 seconds, then start the others.

```bash
# On elk-node1:
sudo systemctl start elasticsearch
sleep 30

# On elk-node2:
sudo systemctl start elasticsearch
sleep 10

# On elk-node3:
sudo systemctl start elasticsearch
```

Verify all 3 nodes joined (from elk-node1):

```bash
curl http://localhost:9200/_cat/nodes?v
```

Expected output:
```
ip            heap.percent  node.role  master  name
192.168.1.101     xx          dm         *     elk-node1
192.168.1.102     xx          d          -     elk-node2
192.168.1.103     xx          d          -     elk-node3
```

> **Troubleshooting — node3 stale cluster UUID:**
> If node3 has data from a previous failed bootstrap, it will refuse to join with:
> `This node previously joined a cluster with UUID [...] and is now trying to join a different cluster`
>
> Fix (on elk-node3):
> ```bash
> sudo systemctl stop elasticsearch
> sudo rm -rf /var/lib/elasticsearch/*
> sudo chown -R elasticsearch:elasticsearch /var/lib/elasticsearch
> sudo systemctl start elasticsearch
> ```

---

## Phase 3 — Set Passwords

Run all password commands **on elk-node1** after the cluster shows 3 nodes and `status: green`.

```bash
# Check cluster health first
curl http://localhost:9200/_cluster/health?pretty
# "status" should be "green", "number_of_nodes" should be 3
```

```bash
# Set elastic (superuser) password
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -i

# Set kibana_system password
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system -i

# Set logstash_system password
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u logstash_system -i
```

> **Note:** Use `elasticsearch-reset-password`, NOT `elasticsearch-setup-passwords`.
> `elasticsearch-setup-passwords` consumes the bootstrap password on first use. If ES was
> restarted or the bootstrap password was already used, it exits with code 78.
> `elasticsearch-reset-password` works at any time.

Verify each password:

```bash
curl -u elastic:YOUR_ELASTIC_PASSWORD http://localhost:9200/_security/_authenticate?pretty
```

---

## Phase 4 — Configure Logstash (elk-node2)

```bash
gcloud compute ssh elk-node2 --zone=asia-south1-a
```

Update the Elasticsearch password in the Logstash pipeline:

```bash
sudo sed -i 's/YOUR_ELASTIC_PASSWORD/YOUR_ACTUAL_ELASTIC_PASSWORD/' \
  /etc/logstash/conf.d/kafka-to-es.conf

# Verify the change
sudo grep "password" /etc/logstash/conf.d/kafka-to-es.conf

# Restart Logstash
sudo systemctl restart logstash
sudo systemctl status logstash | grep "Active:"
```

---

## Phase 5 — Configure Kibana (elk-node3)

```bash
gcloud compute ssh elk-node3 --zone=asia-south1-a
```

```bash
sudo sed -i 's/YOUR_KIBANA_SYSTEM_PASSWORD/YOUR_ACTUAL_KIBANA_SYSTEM_PASSWORD/' \
  /etc/kibana/kibana.yml

# Verify the change
sudo grep "password" /etc/kibana/kibana.yml

# Restart Kibana
sudo systemctl restart kibana
sudo systemctl status kibana | grep "Active:"
```

Kibana takes **60–90 seconds** to fully initialize. Check readiness:

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:5601/api/status
# Should return: 200
```

Access Kibana in your browser:

```
http://<elk-node3-external-ip>:5601
```

Login: `elastic` / `<your elastic password>`

Get node3 external IP:

```bash
gcloud compute instances describe elk-node3 --zone=asia-south1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

---

## Phase 6 — Create Kafka Topic

```bash
gcloud compute ssh elk-node1 --zone=asia-south1-a
```

```bash
/opt/kafka/bin/kafka-topics.sh \
  --create \
  --topic logs \
  --bootstrap-server 192.168.1.101:9092 \
  --partitions 3 \
  --replication-factor 3

# Verify (all 3 brokers should be in Isr)
/opt/kafka/bin/kafka-topics.sh \
  --describe \
  --topic logs \
  --bootstrap-server 192.168.1.101:9092
```

---

## Phase 7 — End-to-End Test

Send a test log message through the full pipeline:

```bash
# On elk-node1 — produce a plain-text Apache log line to Kafka
echo '192.168.1.50 - frank [29/Mar/2026:12:00:00 +0000] "GET /index.html HTTP/1.1" 200 1024 "http://example.com" "Mozilla/5.0"' | \
  /opt/kafka/bin/kafka-console-producer.sh \
  --topic logs \
  --bootstrap-server 192.168.1.101:9092
```

Wait ~15 seconds, then verify the document arrived in Elasticsearch:

```bash
curl -s -u elastic:YOUR_PASSWORD \
  "http://localhost:9200/logs-*/_search?pretty&size=1&sort=@timestamp:desc" | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
h = d['hits']['hits'][0]['_source']
print('clientip:', h.get('clientip', 'MISSING'))
print('verb:    ', h.get('verb', 'MISSING'))
print('response:', h.get('response', 'MISSING'))
print('tags:    ', h.get('tags', 'none'))
"
```

Expected output (no `_grokparsefailure` tag):

```
clientip: 192.168.1.50
verb:     GET
response: 200
tags:     none
```

---

## Kibana — Create Data View

1. Open Kibana: `http://<node3-external-ip>:5601`
2. Login: `elastic` / `<elastic password>`
3. Go to **Stack Management → Data Views**
4. Click **Create data view**
   - Name: `logs`
   - Index pattern: `logs-*`
   - Timestamp field: `@timestamp`
5. Click **Save data view to Kibana**
6. Go to **Discover** to explore your logs

---

## Stopping and Starting the Cluster

### Stop all VMs (saves cost when not in use)

```bash
gcloud compute instances stop elk-node1 elk-node2 elk-node3 --zone=asia-south1-a
```

### Start all VMs

```bash
gcloud compute instances start elk-node1 elk-node2 elk-node3 --zone=asia-south1-a
```

All services (Zookeeper, Kafka, Elasticsearch, Logstash, Kibana) are enabled via systemd and will **auto-start on boot**. Static internal IPs (192.168.1.101-103) are preserved across restarts.

After starting, wait ~2 minutes then verify:

```bash
# Cluster health (from elk-node1)
curl -u elastic:YOUR_PASSWORD http://localhost:9200/_cluster/health?pretty

# All nodes present
curl -u elastic:YOUR_PASSWORD http://localhost:9200/_cat/nodes?v
```

---

## Destroy the Cluster

```bash
cd elk-terraform/
terraform destroy
```

---

## Key Configuration Notes

**Why only elk-node1 in cluster.initial_master_nodes?**
Only elk-node1 has `node.roles: [master, data]`. elk-node2 and elk-node3 have `node.roles: [data]` only. ES requires all nodes listed in `cluster.initial_master_nodes` to be master-eligible. Listing data-only nodes causes the cluster to hang forever waiting for them to participate in the election.

**Why http:// and not https:// for Kibana/Logstash?**
Only transport TLS (port 9300, node-to-node) is configured. HTTP SSL (port 9200, client-facing) is not configured. Connecting Kibana or Logstash with `https://` results in an SSL handshake error because the ES HTTP server responds in plain text.

**Why codec => "plain" in Logstash?**
Using `codec => "json"` in the Kafka input causes double-encoding: when the outer JSON contains a string with embedded quotes (e.g. `"GET /path HTTP/1.1"`), those inner quotes get escaped as `\"`. The grok filter then sees backslash-escaped quotes and fails to match. `codec => "plain"` passes the raw message string directly to grok.

**Why elasticsearch-reset-password instead of elasticsearch-setup-passwords?**
`elasticsearch-setup-passwords` uses a one-time bootstrap password that is consumed on first call. If the command fails or is called more than once, it exits with code 78. `elasticsearch-reset-password` works independently of the bootstrap password and can be used at any time.

---

## Troubleshooting Quick Reference

| Symptom | Cause | Fix |
|---------|-------|-----|
| ES won't start: `keystore password was incorrect` | ES 8.x auto-adds http.ssl entries to keystore | Clear all ssl keystore entries (Phase 2b) |
| ES won't start: `http.ssl.keystore.secure_password set but http.ssl.enabled not configured` | Same as above | Same fix — clear all ssl keystore entries |
| Cluster stuck: `must discover master-eligible nodes [elk-node2, elk-node3]` | data-only nodes listed in `cluster.initial_master_nodes` | Update all nodes: `cluster.initial_master_nodes: ["elk-node1"]` |
| node3 rejected: `previously joined a cluster with UUID [X] and is now trying to join [Y]` | Stale cluster state from previous bootstrap | Stop ES on node3, wipe `/var/lib/elasticsearch/*`, restart |
| `curl https://...:9200` fails with `packet length too long` | HTTP SSL not configured, using https:// | Use `http://` instead |
| `elasticsearch-setup-passwords` exits with code 78 | Bootstrap password already consumed | Use `elasticsearch-reset-password -u elastic -i` instead |
| `gcloud compute scp` permission denied on cert | Cert owned by elasticsearch user | `sudo cp cert /tmp/ && sudo chmod 644 /tmp/cert` then scp from /tmp |
| Logstash `_grokparsefailure` on all events | Using `codec => "json"` causes quote escaping | Use `codec => "plain"` in Kafka input |
| Kafka download is 0 bytes | Version removed from downloads.apache.org | Use `archive.apache.org` (already fixed in scripts) |
| `wget: command not found` | Rocky Linux 9 minimal excludes wget | Add `wget` to `dnf install -y ...` (already fixed in scripts) |
