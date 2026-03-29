#!/bin/bash
# =================================================================
# elk-node3 — Elasticsearch (data) | Zookeeper | Kafka Broker 3 | Kibana
# OS      : Rocky Linux 9
# Cluster : ${cluster_name}
# IP      : ${node_ip}
#
# FIXES APPLIED (from production deployment):
#  - cluster.initial_master_nodes: ["elk-node1"] ONLY
#  - Kibana elasticsearch.hosts uses http:// (not https://) — HTTP SSL
#    is not configured in elasticsearch.yml, only transport SSL. Using
#    https:// causes SSL handshake failures at Kibana startup.
#  - Removed elasticsearch.ssl.verificationMode (not needed with http://)
#  - Kibana logging uses flat key format (not nested YAML) which is
#    compatible across all Kibana 8.x versions
#  - ES started AFTER TLS certs are copied from node1
#  - If node3 has stale cluster state from a previous failed bootstrap,
#    wipe /var/lib/elasticsearch/* before starting ES (see README)
#  - wget added to dnf install
#  - Kafka downloaded from archive.apache.org
# =================================================================
set -e

LOG=/var/log/elk-startup.log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "======================================================="
log "elk-node3 startup — $(date)"
log "======================================================="

# ─── 1. Hostname ─────────────────────────────
log "Setting hostname..."
hostnamectl set-hostname elk-node3

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
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

cat > /etc/sysctl.d/99-elk.conf << 'SYSCTL'
vm.max_map_count=262144
net.ipv4.tcp_retries2=5
SYSCTL
sysctl -p /etc/sysctl.d/99-elk.conf

cat > /etc/security/limits.d/elk.conf << 'LIMITS'
*               soft    nofile          65536
*               hard    nofile          65536
*               soft    nproc           4096
*               hard    nproc           4096
elasticsearch   soft    memlock         unlimited
elasticsearch   hard    memlock         unlimited
kafka           soft    nofile          65536
kafka           hard    nofile          65536
kibana          soft    nofile          65536
kibana          hard    nofile          65536
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
# FIX: Use archive.apache.org — downloads.apache.org only hosts the latest release
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
server.1=elk-node1:2888:3888
server.2=elk-node2:2888:3888
server.3=elk-node3:2888:3888
ZKEOF

echo "${zk_myid}" > /var/lib/zookeeper/myid
chown kafka:kafka /var/lib/zookeeper/myid

log "Configuring Kafka Broker (broker.id=${broker_id})..."
cat > /opt/kafka/config/server.properties << 'KAFKAEOF'
broker.id=3
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://elk-node3:9092
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

# ─── 6. Elasticsearch (data node) ────────────
log "Installing Elasticsearch 8.x (data node)..."

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

log "Configuring Elasticsearch (data-only node)..."
cat > /etc/elasticsearch/elasticsearch.yml << 'ESEOF'
cluster.name: ELK_CLUSTER_NAME_PLACEHOLDER
node.name: elk-node3
# FIX: data-only — master role is on elk-node1 exclusively
node.roles: [data]
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 0.0.0.0
http.port: 9200
discovery.seed_hosts: ["elk-node1", "elk-node2", "elk-node3"]
# FIX: Only master-eligible nodes in cluster.initial_master_nodes.
# elk-node3 has node.roles: [data] — it cannot participate in master election.
cluster.initial_master_nodes: ["elk-node1"]
xpack.security.enabled: true
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.keystore.path: /etc/elasticsearch/certs/elastic-certificates.p12
xpack.security.transport.ssl.truststore.path: /etc/elasticsearch/certs/elastic-certificates.p12
bootstrap.memory_lock: true
ESEOF

sed -i "s/ELK_CLUSTER_NAME_PLACEHOLDER/${cluster_name}/" /etc/elasticsearch/elasticsearch.yml

cat > /etc/elasticsearch/jvm.options.d/heap.options << JVMEOF
-Xms${es_heap_size}
-Xmx${es_heap_size}
JVMEOF

mkdir -p /etc/systemd/system/elasticsearch.service.d
cat > /etc/systemd/system/elasticsearch.service.d/override.conf << 'SVCOVER'
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=65536
SVCOVER

systemctl daemon-reload
systemctl enable elasticsearch
# ⚠️ Do NOT start ES here — TLS certs must be copied from elk-node1 first.
# See README Phase 2.

# ─── 7. Kibana ───────────────────────────────
log "Installing Kibana 8.x..."

# Re-use the elastic repo (already configured above)
dnf install -y kibana

log "Configuring Kibana..."

# Create log directory before writing config
mkdir -p /var/log/kibana
chown kibana:kibana /var/log/kibana

cat > /etc/kibana/kibana.yml << 'KBEOF'
# ── Server ────────────────────────────────────
server.port: 5601
server.host: "0.0.0.0"
server.name: "elk-node3"

# ── Elasticsearch ─────────────────────────────
# FIX: Use http:// not https:// — xpack.security.http.ssl is NOT configured
# in elasticsearch.yml (only transport SSL is). Using https:// causes Kibana
# to attempt a TLS handshake with a plain-HTTP server, resulting in connection
# errors at startup.
elasticsearch.hosts: ["http://elk-node1:9200","http://elk-node2:9200","http://elk-node3:9200"]
elasticsearch.username: "kibana_system"
# ⚠️ Update this after running elasticsearch-reset-password -u kibana_system
elasticsearch.password: "YOUR_KIBANA_SYSTEM_PASSWORD"

# ── Logging ───────────────────────────────────
# FIX: Use flat key format — nested YAML format for logging.appenders
# caused issues on some Kibana 8.x versions. Flat format is compatible
# across all 8.x releases.
logging.appenders.default.type: file
logging.appenders.default.fileName: /var/log/kibana/kibana.log
logging.appenders.default.layout.type: json
logging.root.appenders: [default]
KBEOF

systemctl daemon-reload
systemctl enable kibana
# ⚠️ Kibana will fail to connect to ES until passwords are set.
# After elasticsearch-reset-password -u kibana_system on node1:
#   sudo sed -i 's/YOUR_KIBANA_SYSTEM_PASSWORD/<actual_password>/' /etc/kibana/kibana.yml
#   sudo systemctl restart kibana

# Kibana takes 60-90 seconds to fully initialize on first start.
# Check readiness: curl http://localhost:5601/api/status

log "======================================================="
log "elk-node3 base setup COMPLETE."
log ""
log "NEXT MANUAL STEPS — follow README Phase 2 (TLS setup from node1)"
log ""
log "Quick reference for elk-node3 TLS cert installation:"
log "  # After scp'ing cert from node1 to /tmp on this node:"
log "  sudo mkdir -p /etc/elasticsearch/certs"
log "  sudo cp /tmp/elastic-certificates.p12 /etc/elasticsearch/certs/"
log "  sudo chown -R elasticsearch:elasticsearch /etc/elasticsearch/certs"
log "  sudo chmod 640 /etc/elasticsearch/certs/elastic-certificates.p12"
log ""
log "  # Clear auto-added http.ssl keystore entries:"
log "  for key in \$(sudo /usr/share/elasticsearch/bin/elasticsearch-keystore list | grep ssl); do"
log "    sudo /usr/share/elasticsearch/bin/elasticsearch-keystore remove \$key 2>/dev/null || true"
log "  done"
log "  # Add transport SSL password (press Enter for empty):"
log "  sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add \\"
log "    xpack.security.transport.ssl.keystore.secure_password"
log "  sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add \\"
log "    xpack.security.transport.ssl.truststore.secure_password"
log ""
log "  # IMPORTANT: If this is a re-deployment and /var/lib/elasticsearch"
log "  # has data from a previous cluster (different UUID), wipe it first:"
log "  #   sudo systemctl stop elasticsearch"
log "  #   sudo rm -rf /var/lib/elasticsearch/*"
log "  #   sudo chown -R elasticsearch:elasticsearch /var/lib/elasticsearch"
log "  # Then start Elasticsearch (after node1 and node2 are already running):"
log "  sudo systemctl start elasticsearch"
log ""
log "  # After kibana_system password is set on node1:"
log "  sudo sed -i 's/YOUR_KIBANA_SYSTEM_PASSWORD/<actual_password>/' \\"
log "    /etc/kibana/kibana.yml"
log "  sudo systemctl restart kibana"
KIBANA_EXTERNAL_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" -H "Metadata-Flavor: Google" 2>/dev/null || echo "unknown")
log "  Kibana URL: http://$${KIBANA_EXTERNAL_IP}:5601"
log "======================================================="
