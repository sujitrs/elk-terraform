#!/bin/bash
# =================================================================
# elk-node2 — Elasticsearch (data) | Zookeeper | Kafka Broker 2 | Logstash
# OS      : Rocky Linux 9
# Cluster : ${cluster_name}
# IP      : ${node_ip}
#
# FIXES APPLIED (from production deployment):
#  - cluster.initial_master_nodes: ["elk-node1"] ONLY
#  - ES started AFTER TLS certs are copied from node1
#  - Logstash uses codec => "plain" (not "json") — json codec causes
#    double-encoding of message field which breaks grok parsing
#  - Logstash uses http:// (not https://) for ES output — HTTP SSL is
#    not configured, only transport SSL. Using https:// causes
#    "packet length too long" SSL handshake error
#  - Custom explicit grok pattern replaces %{COMBINEDAPACHELOG} which
#    was unreliable across Logstash versions
#  - Single consolidated pipeline conf file (avoids ordering issues)
#  - ES keystore must be cleared of auto-added http.ssl entries
#  - wget added to dnf install
#  - Kafka downloaded from archive.apache.org
# =================================================================
set -e

LOG=/var/log/elk-startup.log
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "======================================================="
log "elk-node2 startup — $(date)"
log "======================================================="

# ─── 1. Hostname ─────────────────────────────
log "Setting hostname..."
hostnamectl set-hostname elk-node2

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
logstash        soft    nofile          65536
logstash        hard    nofile          65536
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
broker.id=2
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://elk-node2:9092
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
node.name: elk-node2
# FIX: data-only — master role is on elk-node1 exclusively
node.roles: [data]
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 0.0.0.0
http.port: 9200
discovery.seed_hosts: ["elk-node1", "elk-node2", "elk-node3"]
# FIX: Only master-eligible nodes in cluster.initial_master_nodes.
# elk-node2 has node.roles: [data] — it cannot participate in master election.
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

# ─── 7. Logstash (Kafka → Elasticsearch) ─────
log "Installing Logstash 8.x..."

# Re-use the elastic repo (already configured above)
dnf install -y logstash

log "Configuring Logstash JVM heap to ${logstash_heap_size}..."
cat > /etc/logstash/jvm.options.d/heap.options << LSJVMEOF
-Xms${logstash_heap_size}
-Xmx${logstash_heap_size}
LSJVMEOF

cat > /etc/logstash/logstash.yml << 'LSEOF'
node.name: elk-node2-logstash
path.data: /var/lib/logstash
path.logs: /var/log/logstash
pipeline.id: main
pipeline.workers: 2
pipeline.batch.size: 125
xpack.monitoring.enabled: false
LSEOF

log "Creating Logstash Kafka -> Elasticsearch pipeline..."
mkdir -p /etc/logstash/conf.d

# FIX 1: codec => "plain" (not "json")
#   Using codec => "json" causes double-encoding: the outer JSON is parsed
#   but the inner message string retains escaped quotes (e.g. \"GET /...\").
#   When grok tries to match, it sees backslash-escaped quotes and fails.
#   codec => "plain" passes the raw message string directly to grok.
#
# FIX 2: Explicit grok pattern (not %{COMBINEDAPACHELOG})
#   %{COMBINEDAPACHELOG} is a shorthand that varies across Logstash versions.
#   The explicit pattern below is identical in behavior but version-stable.
#   Uses log_timestamp (not timestamp) to avoid collision with @timestamp.
#
# FIX 3: ES output uses http:// (not https://)
#   xpack.security.http.ssl is NOT configured in elasticsearch.yml — only
#   transport SSL is. Connecting with https:// causes an SSL handshake error:
#   "packet length too long" because ES responds with plain HTTP, not TLS.

cat > /etc/logstash/conf.d/kafka-to-es.conf << 'LSPIPELINE'
input {
  kafka {
    bootstrap_servers => "elk-node1:9092,elk-node2:9092,elk-node3:9092"
    topics            => ["logs"]
    group_id          => "logstash-consumer"
    codec             => "plain"
    consumer_threads  => 3
    decorate_events   => true
  }
}

filter {
  grok {
    match => {
      "message" => "%{IPORHOST:clientip} %{USER:ident} %{USER:auth} \[%{HTTPDATE:log_timestamp}\] \"%{WORD:verb} %{NOTSPACE:request} HTTP/%{NUMBER:httpversion}\" %{NUMBER:response} (?:%{NUMBER:bytes}|-) \"%{DATA:referrer}\" \"%{DATA:agent}\""
    }
    tag_on_failure => ["_grokparsefailure"]
  }

  date {
    match  => ["log_timestamp", "dd/MMM/yyyy:HH:mm:ss Z"]
    target => "@timestamp"
  }

  mutate {
    remove_field => ["@version", "log_timestamp"]
  }
}

output {
  elasticsearch {
    # FIX: http:// not https:// — HTTP SSL is not configured in elasticsearch.yml
    hosts    => ["http://elk-node1:9200", "http://elk-node2:9200", "http://elk-node3:9200"]
    index    => "logs-%{+YYYY.MM.dd}"
    user     => "elastic"
    # ⚠️ Update this after running elasticsearch-reset-password on elk-node1
    password => "YOUR_ELASTIC_PASSWORD"
  }
}
LSPIPELINE

systemctl daemon-reload
systemctl enable logstash
# ⚠️ Logstash will connect to Kafka but fail to write to ES until the
# elastic password is set. Update the password in the conf file then:
#   sudo systemctl restart logstash
systemctl start logstash

log "======================================================="
log "elk-node2 base setup COMPLETE."
log ""
log "NEXT MANUAL STEPS — follow README Phase 2 (TLS setup from node1)"
log ""
log "Quick reference for elk-node2 TLS cert installation:"
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
log "  # Start Elasticsearch (after node1 is already running):"
log "  sudo systemctl start elasticsearch"
log ""
log "  # After elastic password is set on node1, update Logstash config:"
log "  sudo sed -i 's/YOUR_ELASTIC_PASSWORD/<actual_password>/' \\"
log "    /etc/logstash/conf.d/kafka-to-es.conf"
log "  sudo systemctl restart logstash"
log "======================================================="
