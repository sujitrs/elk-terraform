#!/bin/bash
# =============================================================
# Verification Script — elk-node3
# Covers: Phase 1 (post-startup), Phase 2 (TLS), Phase 5 (Kibana)
#
# Usage:
#   sudo bash verify-node3.sh
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
echo -e "${CYAN}  elk-node3 Verification Script                  ${NC}"
echo -e "${CYAN}=================================================${NC}"

# ─── 1. Hostname ──────────────────────────────────────────────
section "1. Hostname"
HOSTNAME=$(hostname)
[ "$HOSTNAME" == "elk-node3" ] && pass "Hostname = elk-node3" || fail "Hostname = '$HOSTNAME' (expected: elk-node3)"

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

[ -f /etc/sysctl.d/99-elk.conf ]       && pass "sysctl tuning file exists"  || fail "/etc/sysctl.d/99-elk.conf missing"
[ -f /etc/security/limits.d/elk.conf ] && pass "limits.d/elk.conf exists"   || fail "/etc/security/limits.d/elk.conf missing"

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
[ -d "/opt/kafka" ]                           && pass "/opt/kafka exists"       || fail "/opt/kafka not found"
[ -f "/opt/kafka/bin/kafka-server-start.sh" ] && pass "Kafka binaries present"  || fail "Kafka binaries missing"
[ "$(stat -c '%U' /opt/kafka 2>/dev/null)" == "kafka" ] && pass "Kafka owned by 'kafka'" || fail "Kafka not owned by 'kafka'"

if [ -f "/opt/kafka/config/server.properties" ]; then
    BROKER_ID=$(grep "^broker.id" /opt/kafka/config/server.properties | cut -d= -f2 | tr -d ' ')
    [ "$BROKER_ID" == "3" ] && pass "Kafka broker.id = 3" || fail "Kafka broker.id = '$BROKER_ID' (expected: 3)"

    grep -q "advertised.listeners=PLAINTEXT://elk-node3:9092" /opt/kafka/config/server.properties \
        && pass "Kafka advertised.listeners = elk-node3:9092" \
        || fail "Kafka advertised.listeners not set to elk-node3:9092"

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
    [ "$MYID" == "3" ] && pass "Zookeeper myid = 3" || fail "Zookeeper myid = '$MYID' (expected: 3)"
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
for svc in zookeeper kafka elasticsearch kibana; do
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

KB_STATUS=$(systemctl is-active kibana 2>/dev/null)
[ "$KB_STATUS" == "active" ] && pass "Kibana running" || warn "Kibana not running (will fail until ES is up and password is set)"

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
    grep -q "node.name: elk-node3" "$ES_CONF"        && pass "node.name = elk-node3"      || fail "node.name incorrect"

    # Data-only node check
    NODE_ROLES=$(grep "^node.roles" "$ES_CONF" | head -1)
    if echo "$NODE_ROLES" | grep -q "data" && ! echo "$NODE_ROLES" | grep -q "master"; then
        pass "node.roles = [data] only (correct for data node)"
    else
        fail "node.roles incorrect: '$NODE_ROLES'
        elk-node3 must be data-only: node.roles: [data]"
    fi

    grep -q "xpack.security.enabled: true" "$ES_CONF"              && pass "xpack.security.enabled = true"  || warn "xpack.security.enabled not true"
    grep -q "xpack.security.transport.ssl.enabled: true" "$ES_CONF" && pass "transport SSL enabled"          || fail "transport SSL not enabled"

    # CRITICAL FIX CHECK: cluster.initial_master_nodes must be ONLY elk-node1
    IMN=$(grep "cluster.initial_master_nodes" "$ES_CONF" | head -1)
    if echo "$IMN" | grep -q '"elk-node1"' && ! echo "$IMN" | grep -q '"elk-node2"' && ! echo "$IMN" | grep -q '"elk-node3"'; then
        pass "cluster.initial_master_nodes = [\"elk-node1\"] only (CRITICAL)"
    else
        fail "cluster.initial_master_nodes is wrong: '$IMN'
        MUST be: cluster.initial_master_nodes: [\"elk-node1\"]"
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
        || warn "transport.ssl.keystore.secure_password not set"
    echo "$KEYSTORE_ENTRIES" | grep -q "xpack.security.transport.ssl.truststore.secure_password" \
        && pass "transport.ssl.truststore.secure_password in keystore" \
        || warn "transport.ssl.truststore.secure_password not set"
else
    warn "Keystore not found yet (will exist after cert setup)"
fi

# IMPORTANT: Stale cluster state check
section "11b. Stale Cluster State Check (IMPORTANT for node3)"
# node3 is most prone to stale cluster UUID issues due to failed bootstrap attempts.
# If /var/lib/elasticsearch has old _state data, node3 will refuse to join.
if [ -d "/var/lib/elasticsearch/_state" ]; then
    STATE_FILES=$(sudo ls /var/lib/elasticsearch/_state/ 2>/dev/null | wc -l)
    ES_RUNNING=$(systemctl is-active elasticsearch 2>/dev/null)
    if [ "$ES_RUNNING" == "active" ]; then
        pass "/var/lib/elasticsearch/_state exists ($STATE_FILES files) and ES is running (joined cluster)"
    else
        warn "/var/lib/elasticsearch/_state exists with $STATE_FILES file(s) but ES is not running.
        If ES fails to join with 'previously joined a different cluster UUID' error:
          sudo systemctl stop elasticsearch
          sudo rm -rf /var/lib/elasticsearch/*
          sudo chown -R elasticsearch:elasticsearch /var/lib/elasticsearch
          sudo systemctl start elasticsearch"
    fi
else
    pass "/var/lib/elasticsearch/_state is clean (no stale cluster state)"
fi

# ─── 12. Kibana Configuration ─────────────────────────────────
section "12. Kibana Configuration (Phase 5)"
KB_CONF="/etc/kibana/kibana.yml"
if [ -f "$KB_CONF" ]; then
    pass "kibana.yml exists"

    grep -q "server.port: 5601" "$KB_CONF"     && pass "server.port = 5601"        || fail "server.port not set to 5601"
    grep -q 'server.host: "0.0.0.0"' "$KB_CONF" && pass 'server.host = "0.0.0.0"' || warn "server.host not set to 0.0.0.0 (Kibana may not be externally accessible)"
    grep -q "server.name" "$KB_CONF"            && pass "server.name is set"         || warn "server.name not set"

    # CRITICAL FIX: Kibana must use http:// not https://
    # Only transport SSL is configured. https:// causes SSL handshake failure at Kibana startup.
    KB_HOSTS=$(grep "elasticsearch.hosts" "$KB_CONF" | head -1)
    if echo "$KB_HOSTS" | grep -q "https://"; then
        fail "Kibana elasticsearch.hosts uses https:// — MUST use http://.
        HTTP SSL is not configured in elasticsearch.yml.
        https:// causes Kibana to fail connecting to Elasticsearch."
    elif echo "$KB_HOSTS" | grep -q "http://"; then
        pass "Kibana elasticsearch.hosts uses http:// (correct)"
    else
        warn "Kibana hosts: $KB_HOSTS — verify protocol"
    fi

    grep -q 'elasticsearch.username: "kibana_system"' "$KB_CONF" \
        && pass "Kibana username = kibana_system" \
        || fail "Kibana username not set to kibana_system"

    # Check password is not placeholder
    KB_PASS=$(grep "elasticsearch.password" "$KB_CONF" | head -1)
    if echo "$KB_PASS" | grep -q "YOUR_KIBANA_SYSTEM_PASSWORD"; then
        fail "Kibana password is still placeholder 'YOUR_KIBANA_SYSTEM_PASSWORD'.
        Update with: sudo sed -i 's/YOUR_KIBANA_SYSTEM_PASSWORD/<actual_password>/' $KB_CONF
        Then restart: sudo systemctl restart kibana"
    else
        pass "Kibana password appears to be set"
    fi

    # CRITICAL FIX: logging format — flat key format works across all Kibana 8.x versions
    # Nested YAML format (logging.appenders.default:\n  type: file) can fail on some versions.
    if grep -q "logging.appenders.default.type:" "$KB_CONF"; then
        pass "Kibana logging uses flat key format (correct)"
    elif grep -q "logging:" "$KB_CONF"; then
        warn "Kibana logging uses nested YAML format — may cause issues. Prefer flat key format:
        logging.appenders.default.type: file
        logging.appenders.default.fileName: /var/log/kibana/kibana.log
        logging.appenders.default.layout.type: json
        logging.root.appenders: [default]"
    else
        warn "Kibana logging not configured"
    fi

    # Check ssl.verificationMode is NOT set (not needed with http://)
    if grep -q "elasticsearch.ssl.verificationMode" "$KB_CONF"; then
        warn "elasticsearch.ssl.verificationMode found in kibana.yml — not needed when using http://"
    else
        pass "No ssl.verificationMode in kibana.yml (correct for http://)"
    fi
else
    fail "kibana.yml not found at $KB_CONF"
fi

# ─── 13. Kibana Log Directory ─────────────────────────────────
section "13. Kibana Log Directory"
[ -d "/var/log/kibana" ] && pass "/var/log/kibana exists" || warn "/var/log/kibana missing (create: sudo mkdir -p /var/log/kibana && sudo chown kibana:kibana /var/log/kibana)"
if [ -d "/var/log/kibana" ]; then
    KB_LOG_OWNER=$(stat -c '%U' /var/log/kibana 2>/dev/null)
    [ "$KB_LOG_OWNER" == "kibana" ] && pass "/var/log/kibana owned by kibana" || fail "/var/log/kibana owned by '$KB_LOG_OWNER' (expected: kibana)"
fi

# ─── 14. Kibana HTTP Status ───────────────────────────────────
section "14. Kibana HTTP Readiness (Phase 5)"
if [ "$(systemctl is-active kibana 2>/dev/null)" == "active" ]; then
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:5601/api/status 2>/dev/null)
    case "$HTTP_CODE" in
        200) pass "Kibana /api/status = 200 (ready)" ;;
        503) warn "Kibana /api/status = 503 (starting up or ES not ready — wait 60-90 sec)" ;;
        401) warn "Kibana /api/status = 401 (auth required — Kibana is up but needs credentials)" ;;
        000) fail "Kibana not responding on port 5601 — check: sudo tail -50 /var/log/kibana/kibana.log" ;;
        *)   warn "Kibana /api/status = $HTTP_CODE — check logs" ;;
    esac

    # Check kibana log for errors
    if [ -f "/var/log/kibana/kibana.log" ]; then
        RECENT_ERRORS=$(sudo tail -20 /var/log/kibana/kibana.log 2>/dev/null | grep '"level":"ERROR"' | wc -l)
        CPU_ERR=$(sudo tail -20 /var/log/kibana/kibana.log 2>/dev/null | grep -c "CPU usage.*exceeds threshold" 2>/dev/null || echo 0)
        if [ "$RECENT_ERRORS" -gt 0 ] && [ "$CPU_ERR" -gt 0 ]; then
            warn "Kibana log shows $RECENT_ERRORS recent error(s) — mostly CPU threshold warnings (normal on e2-medium at startup)"
        elif [ "$RECENT_ERRORS" -gt 0 ]; then
            warn "Kibana log shows $RECENT_ERRORS recent error(s) — check: sudo tail -30 /var/log/kibana/kibana.log"
        else
            pass "No recent errors in Kibana log"
        fi
    fi
else
    warn "Kibana not running — start after kibana_system password is set (Phase 5)"
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

# Kibana URL
EXTERNAL_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" -H "Metadata-Flavor: Google" 2>/dev/null || echo "unknown")
echo ""
echo -e "  ${CYAN}Kibana URL: http://${EXTERNAL_IP}:5601${NC}"
echo ""
