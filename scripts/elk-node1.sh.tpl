#!/bin/bash
# =================================================================
# elk-node1 — Elasticsearch (master+data) | Zookeeper | Kafka Broker 1
# OS      : Rocky Linux 9
# Cluster : ${cluster_name}
# IP      : ${node_ip}
#
# FIXES APPLIED (from production deployment):
#  - cluster.initial_master_nodes: ["elk-node1"] ONLY (node1 is the
#    only master-eligible node; adding data-only nodes here causes
#    ES bootstrap to hang waiting for non-master nodes to vote)
#  - xpack.security.http.ssl NOT configured (only transport SSL used;
#    configuring http.ssl without http.ssl.enabled=true causes keystore
#    errors on startup)
#  - wget added to dnf install (Rocky Linux 9 minimal excludes it)
#  - Kafka downloaded from archive.apache.org (downloads.apache.org
#    only hosts the latest release; older versions return 0 bytes)
#  - elasticsearch-reset-password used for password setup (not
#    elasticsearch-setup-passwords which fails after first bootstrap)
# =================================================================
set -e

LOG=/var/log/elk-startup.log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "======================================================="
log "elk-node1 startup — $(date)"
log "======================================================="

# ─── 1. Hostname ─────────────────────────────
log "Setting hostname..."
hostnamectl set-hostname elk-node1

# ─── 2. /etc/hosts ───────────────────────────
log "Configuring /etc/hosts..."
sed -i '/elk-node/d' /etc/hosts
cat >> /etc/hosts << 'HOSTS'
192.168.1.101  elk-node1
192.168.1.102  elk-node2
192.168.1.103  elk-node3
HOSTS

# ─── 3. System tuning ────────────────────────
log "Applying system tuning..."

# Disable swap (required by Elasticsearch)
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Kernel parameters
cat > /etc/sysctl.d/99-elk.conf << 'SYSCTL'
vm.max_map_count=262144
net.ipv4.tcp_retries2=5
SYSCTL
sysctl -p /etc/sysctl.d/99-elk.conf

# File descriptor & process limits
cat > /etc/security/limits.d/elk.conf << 'LIMITS'
*               soft    nofile          65536
*               hard    nofile          65536
*               soft    nproc           4096
*               hard    nproc           4096
elasticsearch   soft    memlock         unlimited
elasticsearch   hard    memlock         unlimited
kafka           soft    nofile          65536
kafka           hard    nofile          65536
LIMITS

# ─── 4. Java 17 ──────────────────────────────
log "Installing Java 17..."
# wget is included here — Rocky Linux 9 minimal does NOT include it by default
dnf install -y java-17-openjdk java-17-openjdk-devel wget
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
echo 'export JAVA_HOME=/usr/lib/jvm/java-17-openjdk' >> /etc/profile.d/java.sh
echo 'export PATH=$JAVA_HOME/bin:$PATH' >> /etc/profile.d/java.sh
java -version

# ─── 5. Kafka + Zookeeper ────────────────────
log "Installing Kafka ${kafka_version} + Zookeeper..."

KAFKA_PKG="kafka_${kafka_scala_version}-${kafka_version}"
# FIX: Use archive.apache.org — downloads.apache.org only hosts the latest
# release. Older versions return a 0-byte file which causes tar to fail.
KAFKA_URL="https://archive.apache.org/dist/kafka/${kafka_version}/$${KAFKA_PKG}.tgz"

cd /opt
wget -q "$KAFKA_URL" -O kafka.tgz
tar -xzf kafka.tgz
mv "$KAFKA_PKG" kafka
rm -f kafka.tgz

useradd -r -s /sbin/nologin kafka 2>/dev/null || true
chown -R kafka:kafka /opt/kafka

mkdir -p /var/lib/zookeeper /var/log/kafka
chown -R kafka:kafka /var/lib/zookeeper /var/log/kafka

log "Configuring Zookeeper (myid=${zk_myid})..."
cat > /opt/kafka/config/zookeeper.properties << 'ZKEOF'
dataDir=/var/lib/zookeeper
clientPort=2181
maxClientCnxns=60
tickTime=2000
initLimit=10
syncLimit=5
# Cluster peers
server.1=elk-node1:2888:3888
server.2=elk-node2:2888:3888
server.3=elk-node3:2888:3888
ZKEOF

echo "${zk_myid}" > /var/lib/zookeeper/myid
chown kafka:kafka /var/lib/zookeeper/myid

log "Configuring Kafka Broker (broker.id=${broker_id})..."
cat > /opt/kafka/config/server.properties << 'KAFKAEOF'
broker.id=1
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://elk-node1:9092
num.network.threads=3
num.io.threads=8
log.dirs=/var/log/kafka
num.partitions=3
default.replication.factor=3
min.insync.replicas=2
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
zookeeper.connect=elk-node1:2181,elk-node2:2181,elk-node3:2181
zookeeper.connection.timeout.ms=18000
auto.create.topics.enable=true
group.initial.rebalance.delay.ms=3000
KAFKAEOF

log "Creating Zookeeper systemd service..."
cat > /etc/systemd/system/zookeeper.service << 'ZKSVC'
[Unit]
Description=Apache Zookeeper
After=network.target

[Service]
Type=simple
User=kafka
Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk"
ExecStart=/opt/kafka/bin/zookeeper-server-start.sh /opt/kafka/config/zookeeper.properties
ExecStop=/opt/kafka/bin/zookeeper-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
ZKSVC

log "Creating Kafka systemd service..."
cat > /etc/systemd/system/kafka.service << 'KAFKASVC'
[Unit]
Description=Apache Kafka
Requires=zookeeper.service
After=zookeeper.service

[Service]
Type=simple
User=kafka
Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk"
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
KAFKASVC

systemctl daemon-reload
systemctl enable zookeeper kafka
log "Starting Zookeeper..."
systemctl start zookeeper
sleep 15
log "Starting Kafka..."
systemctl start kafka

# ─── 6. Elasticsearch ─────────────────────────
log "Installing Elasticsearch 8.x..."

rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch

cat > /etc/yum.repos.d/elasticsearch.repo << 'ESREPO'
[elasticsearch]
name=Elasticsearch repository for 8.x packages
baseurl=https://artifacts.elastic.co/packages/8.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
ESREPO

dnf install -y elasticsearch

log "Configuring Elasticsearch (master+data node)..."
cat > /etc/elasticsearch/elasticsearch.yml << 'ESEOF'
# ── Cluster ───────────────────────────────────
cluster.name: ELK_CLUSTER_NAME_PLACEHOLDER

# ── Node ──────────────────────────────────────
node.name: elk-node1
# FIX: Only elk-node1 has master role. elk-node2 and elk-node3 are data-only.
# If you add data-only nodes to cluster.initial_master_nodes, ES waits
# indefinitely for those nodes to vote — they never will, so the cluster
# never bootstraps.
node.roles: [master, data]

# ── Paths ─────────────────────────────────────
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

# ── Network ───────────────────────────────────
network.host: 0.0.0.0
http.port: 9200

# ── Discovery ─────────────────────────────────
discovery.seed_hosts: ["elk-node1", "elk-node2", "elk-node3"]
# FIX: Only list master-eligible nodes here. elk-node2 and elk-node3
# have node.roles: [data] — they are NOT master-eligible.
# Listing them in cluster.initial_master_nodes causes the cluster to
# hang at bootstrap ("must discover master-eligible nodes [elk-node2, elk-node3]").
cluster.initial_master_nodes: ["elk-node1"]

# ── Security (Transport TLS only) ─────────────
# FIX: Only transport SSL is configured. Do NOT set xpack.security.http.ssl.*
# here — enabling HTTP SSL requires ssl.enabled=true and a separate cert in
# the keystore. Without it, ES 8.x auto-populates http.ssl keystore entries
# that cause "http.ssl.keystore.secure_password set but http.ssl.enabled not
# configured" errors at startup.
xpack.security.enabled: true
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.keystore.path: /etc/elasticsearch/certs/elastic-certificates.p12
xpack.security.transport.ssl.truststore.path: /etc/elasticsearch/certs/elastic-certificates.p12

# ── Performance ───────────────────────────────
bootstrap.memory_lock: true
ESEOF

# Inject real cluster name
sed -i "s/ELK_CLUSTER_NAME_PLACEHOLDER/${cluster_name}/" /etc/elasticsearch/elasticsearch.yml

log "Setting Elasticsearch JVM heap to ${es_heap_size}..."
cat > /etc/elasticsearch/jvm.options.d/heap.options << JVMEOF
-Xms${es_heap_size}
-Xmx${es_heap_size}
JVMEOF

# Allow memory lock
mkdir -p /etc/systemd/system/elasticsearch.service.d
cat > /etc/systemd/system/elasticsearch.service.d/override.conf << 'SVCOVER'
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=65536
SVCOVER

systemctl daemon-reload
systemctl enable elasticsearch
# ⚠️ Do NOT start ES here — TLS certs must be generated first.
# See README Phase 2.

log "======================================================="
log "elk-node1 base setup COMPLETE."
log ""
log "NEXT MANUAL STEPS — follow README Phase 2 (TLS) then Phase 3 (passwords)"
log ""
log "Quick reference (full details in README):"
log "  Phase 2a — Generate TLS certs (on node1 only):"
log "    sudo /usr/share/elasticsearch/bin/elasticsearch-certutil ca \\"
log "      --out /tmp/elastic-stack-ca.p12 --pass \"\""
log "    sudo /usr/share/elasticsearch/bin/elasticsearch-certutil cert \\"
log "      --ca /tmp/elastic-stack-ca.p12 --ca-pass \"\" \\"
log "      --out /tmp/elastic-certificates.p12 --pass \"\""
log "    sudo mkdir -p /etc/elasticsearch/certs"
log "    sudo cp /tmp/elastic-certificates.p12 /etc/elasticsearch/certs/"
log "    sudo chown -R elasticsearch:elasticsearch /etc/elasticsearch/certs"
log "    sudo chmod 640 /etc/elasticsearch/certs/elastic-certificates.p12"
log ""
log "  Phase 2b — Configure keystore (on node1 only):"
log "    # Clear any auto-added http.ssl entries from ES 8.x install"
log "    for key in \$(sudo /usr/share/elasticsearch/bin/elasticsearch-keystore list | grep ssl); do"
log "      sudo /usr/share/elasticsearch/bin/elasticsearch-keystore remove \$key 2>/dev/null || true"
log "    done"
log "    # Add transport SSL password (press Enter for empty password)"
log "    sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add \\"
log "      xpack.security.transport.ssl.keystore.secure_password"
log "    sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add \\"
log "      xpack.security.transport.ssl.truststore.secure_password"
log ""
log "  Phase 2c — Copy certs to elk-node2 and elk-node3 (from your Mac):"
log "    sudo cp /etc/elasticsearch/certs/elastic-certificates.p12 /tmp/"
log "    sudo chmod 644 /tmp/elastic-certificates.p12"
log "    # Then from Mac:"
log "    gcloud compute scp elk-node1:/tmp/elastic-certificates.p12 /tmp/ --zone=asia-south1-a"
log "    gcloud compute scp /tmp/elastic-certificates.p12 elk-node2:/tmp/ --zone=asia-south1-a"
log "    gcloud compute scp /tmp/elastic-certificates.p12 elk-node3:/tmp/ --zone=asia-south1-a"
log ""
log "  Phase 2d — On elk-node2 and elk-node3, install cert + keystore (see README)"
log ""
log "  Phase 2e — Start ES: node1 first, then node2, then node3"
log "    sudo systemctl start elasticsearch"
log "    # Check cluster health after all 3 nodes start:"
log "    curl http://localhost:9200/_cluster/health?pretty"
log ""
log "  Phase 3 — Set passwords (on node1, after cluster is green):"
log "    sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -i"
log "    sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system -i"
log "    sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u logstash_system -i"
log "======================================================="
