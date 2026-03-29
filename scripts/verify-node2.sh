#!/bin/bash
# =============================================================
# Verification Script — elk-node2
# Covers: Phase 1 (post-startup), Phase 2 (TLS), Phase 4 (Logstash)
#
# Usage:
#   sudo bash verify-node2.sh
# =============================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0; FAIL=0; WARN=0

pass()    { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
warn()    { echo -e "  ${YELLOW}[WARN]${NC} $1"; ((WARN++)); }
section() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

echo ""
echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}  elk-node2 Verification Script                  ${NC}"
echo -e "${CYAN}=================================================${NC}"

# ─── 1. Hostname ──────────────────────────────────────────────
section "1. Hostname"
HOSTNAME=$(hostname)
[ "$HOSTNAME" == "elk-node2" ] && pass "Hostname = elk-node2" || fail "Hostname = '$HOSTNAME' (expected: elk-node2)"

# ─── 2. /etc/hosts ────────────────────────────────────────────
section "2. /etc/hosts"
for pair in "192.168.1.101:elk-node1" "192.168.1.102:elk-node2" "192.168.1.103:elk-node3"; do
    IP="${pair%%:*}"; HOST="${pair##*:}"
    grep -q "$IP" /etc/hosts && grep -q "$HOST" /etc/hosts \
        && pass "$HOST ($IP) in /etc/hosts" \
        || fail "$HOST ($IP) missing from /etc/hosts"
done

# ─── 3. System Tuning ─────────────────────────────────────────
section "3. System Tuning"
MAP=$(sysctl -n vm.max_map_count 2>/dev/null)
[ "${MAP:-0}" -ge 262144 ] 2>/dev/null && pass "vm.max_map_count = $MAP" || fail "vm.max_map_count = $MAP (need >= 262144)"

SWAP=$(swapon --show 2>/dev/null | wc -l)
[ "$SWAP" -eq 0 ] && pass "Swap disabled" || warn "Swap is active"

NOFILE=$(ulimit -n 2>/dev/null)
[ "${NOFILE:-0}" -ge 65536 ] 2>/dev/null && pass "ulimit -n = $NOFILE" || warn "ulimit -n = $NOFILE (need >= 65536)"

[ -f /etc/sysctl.d/99-elk.conf ]          && pass "sysctl tuning file exists"    || fail "/etc/sysctl.d/99-elk.conf missing"
[ -f /etc/security/limits.d/elk.conf ]    && pass "limits.d/elk.conf exists"     || fail "/etc/security/limits.d/elk.conf missing"

# ─── 4. Java ──────────────────────────────────────────────────
section "4. Java 17"
if command -v java &>/dev/null; then
    JVER=$(java -version 2>&1 | head -1)
    echo "$JVER" | grep -q "17" && pass "Java 17: $JVER" || fail "Wrong Java version: $JVER"
else
    fail "Java not found"
fi
[ -d "/usr/lib/jvm/java-17-openjdk" ] && pass "JAVA_HOME path exists" || warn "/usr/lib/jvm/java-17-openjdk not found"

# ─── 5. Kafka Installation ────────────────────────────────────
section "5. Kafka Installation"
[ -d "/opt/kafka" ]                           && pass "/opt/kafka exists"         || fail "/opt/kafka not found"
[ -f "/opt/kafka/bin/kafka-server-start.sh" ] && pass "Kafka binaries present"   || fail "Kafka binaries missing"
[ "$(stat -c '%U' /opt/kafka 2>/dev/null)" == "kafka" ] && pass "Kafka owned by 'kafka'" || fail "Kafka not owned by 'kafka'"

if [ -f "/opt/kafka/config/server.properties" ]; then
    BROKER_ID=$(grep "^broker.id" /opt/kafka/config/server.properties | cut -d= -f2 | tr -d ' ')
    [ "$BROKER_ID" == "2" ] && pass "Kafka broker.id = 2" || fail "Kafka broker.id = '$BROKER_ID' (expected: 2)"

    grep -q "advertised.listeners=PLAINTEXT://elk-node2:9092" /opt/kafka/config/server.properties \
        && pass "Kafka advertised.listeners = elk-node2:9092" \
        || fail "Kafka advertised.listeners not set to elk-node2:9092"

    ZK=$(grep "^zookeeper.connect" /opt/kafka/config/server.properties)
    echo "$ZK" | grep -q "elk-node1" && echo "$ZK" | grep -q "elk-node2" && echo "$ZK" | grep -q "elk-node3" \
        && pass "Kafka zookeeper.connect references all 3 nodes" \
        || fail "Kafka zookeeper.connect missing nodes"
else
    fail "Kafka server.properties not found"
fi

# ─── 6. Zookeeper ─────────────────────────────────────────────
section "6. Zookeeper"
if [ -f "/var/lib/zookeeper/myid" ]; then
    MYID=$(cat /var/lib/zookeeper/myid)
    [ "$MYID" == "2" ] && pass "Zookeeper myid = 2" || fail "Zookeeper myid = '$MYID' (expected: 2)"
else
    fail "/var/lib/zookeeper/myid not found"
fi

grep -q "server.1=elk-node1:2888:3888" /opt/kafka/config/zookeeper.properties 2>/dev/null \
 && grep -q "server.2=elk-node2:2888:3888" /opt/kafka/config/zookeeper.properties 2>/dev/null \
 && grep -q "server.3=elk-node3:2888:3888" /opt/kafka/config/zookeeper.properties 2>/dev/null \
    && pass "Zookeeper peer config has all 3 nodes" \
    || fail "Zookeeper peer config incomplete"

# ─── 7. Systemd Services ──────────────────────────────────────
section "7. Systemd Services"
for svc in zookeeper kafka elasticsearch logstash; do
    systemctl is-enabled "$svc" &>/dev/null \
        && pass "$svc enabled" \
        || fail "$svc NOT enabled"
done

for svc in zookeeper kafka; do
    [ "$(systemctl is-active $svc 2>/dev/null)" == "active" ] \
        && pass "$svc running" \
        || fail "$svc NOT running"
done

ES_STATUS=$(systemctl is-active elasticsearch 2>/dev/null)
if [ "$ES_STATUS" == "active" ]; then
    warn "Elasticsearch running — verify TLS certs and keystore are correct"
else
    pass "Elasticsearch not yet started (correct — start after TLS setup)"
fi

LS_STATUS=$(systemctl is-active logstash 2>/dev/null)
[ "$LS_STATUS" == "active" ] && pass "Logstash running" || warn "Logstash not running (will fail until ES is up and password is set)"

# ─── 8. Zookeeper Health ──────────────────────────────────────
section "8. Zookeeper Health Check"
if command -v nc &>/dev/null; then
    ZK_RESP=$(echo ruok | nc -w 2 localhost 2181 2>/dev/null)
    [ "$ZK_RESP" == "imok" ] && pass "Zookeeper local: imok" || fail "Zookeeper not responding on port 2181"
else
    warn "nc not installed — skipping ZK health check (install: sudo dnf install -y nmap-ncat)"
fi

# ─── 9. Elasticsearch Config ──────────────────────────────────
section "9. Elasticsearch Configuration"
ES_CONF="/etc/elasticsearch/elasticsearch.yml"
if [ -f "$ES_CONF" ]; then
    pass "elasticsearch.yml exists"

    grep -q "cluster.name: elk-cluster" "$ES_CONF"  && pass "cluster.name = elk-cluster" || fail "cluster.name incorrect"
    grep -q "node.name: elk-node2" "$ES_CONF"        && pass "node.name = elk-node2"      || fail "node.name incorrect"

    # Data-only node check
    NODE_ROLES=$(grep "^node.roles" "$ES_CONF" | head -1)
    if echo "$NODE_ROLES" | grep -q "data" && ! echo "$NODE_ROLES" | grep -q "master"; then
        pass "node.roles = [data] only (correct for data node)"
    else
        fail "node.roles incorrect: '$NODE_ROLES'
        elk-node2 must be data-only: node.roles: [data]
        Adding master role here would affect cluster elections."
    fi

    grep -q "xpack.security.enabled: true" "$ES_CONF"             && pass "xpack.security.enabled = true"   || warn "xpack.security.enabled not true"
    grep -q "xpack.security.transport.ssl.enabled: true" "$ES_CONF" && pass "transport SSL enabled"          || fail "transport SSL not enabled"

    # CRITICAL FIX CHECK: cluster.initial_master_nodes must be ONLY elk-node1
    IMN=$(grep "cluster.initial_master_nodes" "$ES_CONF" | head -1)
    if echo "$IMN" | grep -q '"elk-node1"' && ! echo "$IMN" | grep -q '"elk-node2"' && ! echo "$IMN" | grep -q '"elk-node3"'; then
        pass "cluster.initial_master_nodes = [\"elk-node1\"] only (CRITICAL)"
    else
        fail "cluster.initial_master_nodes is wrong: '$IMN'
        MUST be: cluster.initial_master_nodes: [\"elk-node1\"]
        This causes cluster bootstrap to hang if data-only nodes are listed."
    fi

    # CRITICAL FIX CHECK: no http.ssl config
    if grep -q "xpack.security.http.ssl" "$ES_CONF"; then
        fail "xpack.security.http.ssl.* found — REMOVE IT (causes keystore startup error)"
    else
        pass "No http.ssl config in elasticsearch.yml (correct)"
    fi
else
    fail "elasticsearch.yml not found"
fi

[ -f "/etc/elasticsearch/jvm.options.d/heap.options" ] \
    && pass "JVM heap options: $(grep Xms /etc/elasticsearch/jvm.options.d/heap.options | head -1)" \
    || fail "JVM heap options file missing"
[ -f "/etc/systemd/system/elasticsearch.service.d/override.conf" ] \
    && pass "Elasticsearch LimitMEMLOCK override exists" \
    || fail "Elasticsearch systemd override missing"

# ─── 10. TLS Certificates ─────────────────────────────────────
section "10. TLS Certificates (Phase 2)"
CERT="/etc/elasticsearch/certs/elastic-certificates.p12"
if [ -f "$CERT" ]; then
    pass "TLS cert exists: $CERT"
    CERT_OWNER=$(stat -c '%U' "$CERT" 2>/dev/null)
    [ "$CERT_OWNER" == "elasticsearch" ] && pass "Cert owned by 'elasticsearch'" || fail "Cert owned by '$CERT_OWNER'"
else
    warn "TLS cert not in place — copy from elk-node1 (Phase 2c in README)"
fi

# ─── 11. Keystore ─────────────────────────────────────────────
section "11. Elasticsearch Keystore (Phase 2d)"
if [ -f "/etc/elasticsearch/elasticsearch.keystore" ]; then
    KEYSTORE_ENTRIES=$(sudo /usr/share/elasticsearch/bin/elasticsearch-keystore list 2>/dev/null)

    # CRITICAL: http.ssl entries cause ES startup failure when http SSL is not configured
    if echo "$KEYSTORE_ENTRIES" | grep -q "http.ssl"; then
        fail "http.ssl entries in keystore — remove with:
        for key in \$(sudo /usr/share/elasticsearch/bin/elasticsearch-keystore list | grep ssl); do
          sudo /usr/share/elasticsearch/bin/elasticsearch-keystore remove \"\$key\"
        done"
    else
        pass "No http.ssl entries in keystore (correct)"
    fi

    echo "$KEYSTORE_ENTRIES" | grep -q "xpack.security.transport.ssl.keystore.secure_password" \
        && pass "transport.ssl.keystore.secure_password in keystore" \
        || warn "transport.ssl.keystore.secure_password not set (set after cert is copied)"
    echo "$KEYSTORE_ENTRIES" | grep -q "xpack.security.transport.ssl.truststore.secure_password" \
        && pass "transport.ssl.truststore.secure_password in keystore" \
        || warn "transport.ssl.truststore.secure_password not set"
else
    warn "Keystore not found yet (will exist after cert setup)"
fi

# ─── 12. Logstash Configuration ───────────────────────────────
section "12. Logstash Configuration (Phase 4)"
LS_CONF="/etc/logstash/conf.d/kafka-to-es.conf"
if [ -f "$LS_CONF" ]; then
    pass "Logstash pipeline config exists: $LS_CONF"

    # CRITICAL FIX: codec must be "plain" not "json"
    # codec => "json" causes double-encoding of message field, breaking grok.
    CODEC=$(grep "codec" "$LS_CONF" | head -1 | tr -d ' ')
    if echo "$CODEC" | grep -q '"plain"'; then
        pass "Logstash codec = \"plain\" (correct)"
    elif echo "$CODEC" | grep -q '"json"'; then
        fail "Logstash codec = \"json\" — MUST be \"plain\".
        json codec double-encodes quotes in message, causing grok failures.
        Change to: codec => \"plain\""
    else
        warn "Logstash codec not clearly set: $CODEC"
    fi

    # CRITICAL FIX: ES output must use http:// not https://
    # Only transport SSL is configured. https:// causes SSL handshake error.
    ES_HOSTS=$(grep "hosts" "$LS_CONF" | grep -v "#" | head -1)
    if echo "$ES_HOSTS" | grep -q "https://"; then
        fail "Logstash ES output uses https:// — MUST use http://.
        HTTP SSL is not configured in elasticsearch.yml.
        https:// causes 'packet length too long' SSL error."
    elif echo "$ES_HOSTS" | grep -q "http://"; then
        pass "Logstash ES output uses http:// (correct)"
    else
        warn "Logstash ES hosts: $ES_HOSTS — verify protocol"
    fi

    # Verify password has been updated from placeholder
    LS_PASS=$(grep "password" "$LS_CONF" | grep -v "#" | head -1)
    if echo "$LS_PASS" | grep -q "YOUR_ELASTIC_PASSWORD"; then
        fail "Logstash elastic password is still placeholder 'YOUR_ELASTIC_PASSWORD'
        Update with: sudo sed -i 's/YOUR_ELASTIC_PASSWORD/<actual_password>/' $LS_CONF
        Then restart: sudo systemctl restart logstash"
    else
        pass "Logstash elastic password appears to be set"
    fi

    # Check Kafka input topic
    grep -q '"logs"' "$LS_CONF" && pass "Logstash input topic = logs" || warn "Logstash topic may not be 'logs'"

    # Check Kafka bootstrap servers
    grep -q "elk-node1:9092" "$LS_CONF" && grep -q "elk-node2:9092" "$LS_CONF" && grep -q "elk-node3:9092" "$LS_CONF" \
        && pass "Logstash Kafka bootstrap_servers reference all 3 brokers" \
        || fail "Logstash bootstrap_servers missing brokers"
else
    fail "Logstash pipeline config not found: $LS_CONF"
fi

[ -f "/etc/logstash/jvm.options.d/heap.options" ] \
    && pass "Logstash JVM heap options exist" \
    || warn "Logstash JVM heap options missing"
[ -f "/etc/logstash/logstash.yml" ] \
    && pass "logstash.yml exists" \
    || fail "logstash.yml not found"

# ─── 13. Logstash Connectivity to ES ──────────────────────────
section "13. Logstash → Elasticsearch Connectivity"
if [ "$(systemctl is-active elasticsearch 2>/dev/null)" == "active" ]; then
    ES_REACHABLE=$(curl -sf http://localhost:9200/ 2>/dev/null)
    [ -n "$ES_REACHABLE" ] && pass "Elasticsearch port 9200 reachable from node2" || fail "Cannot reach Elasticsearch on port 9200"
else
    warn "Elasticsearch not running — skip connectivity check"
fi

# ─── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}  SUMMARY                                        ${NC}"
echo -e "${CYAN}=================================================${NC}"
echo -e "  ${GREEN}PASS${NC}: $PASS  ${RED}FAIL${NC}: $FAIL  ${YELLOW}WARN${NC}: $WARN"
echo ""
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "  ${GREEN}✅ All checks passed!${NC}"
elif [ "$FAIL" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠️  No failures but $WARN warning(s) — review before proceeding.${NC}"
else
    echo -e "  ${RED}❌ $FAIL check(s) failed — fix issues above before proceeding.${NC}"
fi
echo ""
