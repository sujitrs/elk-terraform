#!/bin/bash
# =============================================================
# Verification Script — elk-node1
# Covers: Phase 1 (post-startup), Phase 2 (TLS), Phase 3 (passwords)
#
# Usage:
#   sudo bash verify-node1.sh
#
# Run after each phase to confirm readiness before proceeding.
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
echo -e "${CYAN}  elk-node1 Verification Script                  ${NC}"
echo -e "${CYAN}=================================================${NC}"

# ─── 1. Hostname ──────────────────────────────────────────────
section "1. Hostname"
HOSTNAME=$(hostname)
[ "$HOSTNAME" == "elk-node1" ] && pass "Hostname = elk-node1" || fail "Hostname = '$HOSTNAME' (expected: elk-node1)"

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
[ "$SWAP" -eq 0 ] && pass "Swap disabled" || warn "Swap is active (ES prefers swap off)"

NOFILE=$(ulimit -n 2>/dev/null)
[ "${NOFILE:-0}" -ge 65536 ] 2>/dev/null && pass "ulimit -n = $NOFILE" || warn "ulimit -n = $NOFILE (need >= 65536 — relogin may be required)"

[ -f /etc/sysctl.d/99-elk.conf ] && pass "sysctl tuning file exists" || fail "/etc/sysctl.d/99-elk.conf missing"
[ -f /etc/security/limits.d/elk.conf ] && pass "limits.d/elk.conf exists" || fail "/etc/security/limits.d/elk.conf missing"

# ─── 4. Java ──────────────────────────────────────────────────
section "4. Java 17"
if command -v java &>/dev/null; then
    JVER=$(java -version 2>&1 | head -1)
    echo "$JVER" | grep -q "17" && pass "Java 17: $JVER" || fail "Wrong Java version: $JVER"
else
    fail "Java not found"
fi
[ -d "/usr/lib/jvm/java-17-openjdk" ] && pass "JAVA_HOME path exists" || warn "JAVA_HOME path /usr/lib/jvm/java-17-openjdk not found"

# ─── 5. Kafka Installation ────────────────────────────────────
section "5. Kafka Installation"
[ -d "/opt/kafka" ]                          && pass "/opt/kafka directory exists"          || fail "/opt/kafka not found"
[ -f "/opt/kafka/bin/kafka-server-start.sh" ] && pass "Kafka binaries present"              || fail "Kafka binaries missing"
[ "$(stat -c '%U' /opt/kafka 2>/dev/null)" == "kafka" ] && pass "Kafka owned by 'kafka'" || fail "Kafka not owned by 'kafka'"
[ -d "/var/log/kafka" ]                      && pass "/var/log/kafka exists"                || fail "/var/log/kafka missing"

if [ -f "/opt/kafka/config/server.properties" ]; then
    BROKER_ID=$(grep "^broker.id" /opt/kafka/config/server.properties | cut -d= -f2 | tr -d ' ')
    [ "$BROKER_ID" == "1" ] && pass "Kafka broker.id = 1" || fail "Kafka broker.id = '$BROKER_ID' (expected: 1)"

    grep -q "advertised.listeners=PLAINTEXT://elk-node1:9092" /opt/kafka/config/server.properties \
        && pass "Kafka advertised.listeners = elk-node1:9092" \
        || fail "Kafka advertised.listeners not set to elk-node1:9092"

    ZK=$(grep "^zookeeper.connect" /opt/kafka/config/server.properties)
    echo "$ZK" | grep -q "elk-node1" && echo "$ZK" | grep -q "elk-node2" && echo "$ZK" | grep -q "elk-node3" \
        && pass "Kafka zookeeper.connect references all 3 nodes" \
        || fail "Kafka zookeeper.connect missing nodes: $ZK"
else
    fail "Kafka server.properties not found"
fi

# ─── 6. Zookeeper ─────────────────────────────────────────────
section "6. Zookeeper"
if [ -f "/var/lib/zookeeper/myid" ]; then
    MYID=$(cat /var/lib/zookeeper/myid)
    [ "$MYID" == "1" ] && pass "Zookeeper myid = 1" || fail "Zookeeper myid = '$MYID' (expected: 1)"
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
for svc in zookeeper kafka elasticsearch; do
    systemctl is-enabled "$svc" &>/dev/null \
        && pass "$svc enabled"   \
        || fail "$svc NOT enabled (sudo systemctl enable $svc)"
done

for svc in zookeeper kafka; do
    [ "$(systemctl is-active $svc 2>/dev/null)" == "active" ] \
        && pass "$svc is running" \
        || fail "$svc is NOT running"
done

# ES should not be running until TLS certs are in place
ES_STATUS=$(systemctl is-active elasticsearch 2>/dev/null)
if [ "$ES_STATUS" == "active" ]; then
    warn "Elasticsearch is running — verify TLS certs and keystore are correct"
else
    pass "Elasticsearch not yet started (correct — start after TLS setup)"
fi

# ─── 8. Zookeeper Health ──────────────────────────────────────
section "8. Zookeeper Health Check"
if command -v nc &>/dev/null; then
    ZK_RESP=$(echo ruok | nc -w 2 localhost 2181 2>/dev/null)
    [ "$ZK_RESP" == "imok" ] && pass "Zookeeper local: imok" || fail "Zookeeper not responding on port 2181"
else
    warn "nc not installed (install: sudo dnf install -y nmap-ncat) — skipping ZK health check"
fi

# ─── 9. Elasticsearch Config ──────────────────────────────────
section "9. Elasticsearch Configuration"
ES_CONF="/etc/elasticsearch/elasticsearch.yml"
if [ -f "$ES_CONF" ]; then
    pass "elasticsearch.yml exists"

    grep -q "cluster.name: elk-cluster" "$ES_CONF"           && pass "cluster.name = elk-cluster"         || fail "cluster.name not set correctly"
    grep -q "node.name: elk-node1" "$ES_CONF"                 && pass "node.name = elk-node1"              || fail "node.name incorrect"
    grep -q "node.roles: \[master, data\]" "$ES_CONF"         && pass "node.roles = [master, data]"        || fail "node.roles incorrect (need [master, data])"
    grep -q "xpack.security.enabled: true" "$ES_CONF"         && pass "xpack.security.enabled = true"      || warn "xpack.security.enabled not true"
    grep -q "xpack.security.transport.ssl.enabled: true" "$ES_CONF" && pass "transport SSL enabled"        || fail "transport SSL not enabled"

    # CRITICAL FIX CHECK: cluster.initial_master_nodes must be ONLY elk-node1
    # Listing data-only nodes (elk-node2, elk-node3) causes cluster bootstrap to hang.
    IMN=$(grep "cluster.initial_master_nodes" "$ES_CONF" | head -1)
    if echo "$IMN" | grep -q '"elk-node1"' && ! echo "$IMN" | grep -q '"elk-node2"' && ! echo "$IMN" | grep -q '"elk-node3"'; then
        pass "cluster.initial_master_nodes = [\"elk-node1\"] only (CRITICAL)"
    else
        fail "cluster.initial_master_nodes is wrong: '$IMN'
        MUST be: cluster.initial_master_nodes: [\"elk-node1\"]
        elk-node2 and elk-node3 are data-only — they cannot vote in master election"
    fi

    # CRITICAL FIX CHECK: http.ssl must NOT be configured
    # ES 8.x auto-adds http.ssl keystore entries — if http.ssl.* appears in yml without
    # http.ssl.enabled=true, ES fails: "http.ssl.keystore.secure_password set but http.ssl.enabled not configured"
    if grep -q "xpack.security.http.ssl" "$ES_CONF"; then
        fail "xpack.security.http.ssl.* found in elasticsearch.yml — REMOVE IT.
        Only transport SSL is configured. HTTP SSL causes keystore startup errors."
    else
        pass "No http.ssl config in elasticsearch.yml (correct)"
    fi

    grep -q "bootstrap.memory_lock: true" "$ES_CONF"          && pass "bootstrap.memory_lock = true"       || warn "bootstrap.memory_lock not set"
else
    fail "elasticsearch.yml not found"
fi

[ -f "/etc/elasticsearch/jvm.options.d/heap.options" ] \
    && pass "JVM heap options file exists: $(grep Xms /etc/elasticsearch/jvm.options.d/heap.options | head -1)" \
    || fail "JVM heap options file missing"

[ -f "/etc/systemd/system/elasticsearch.service.d/override.conf" ] \
    && pass "Elasticsearch systemd LimitMEMLOCK override exists" \
    || fail "Elasticsearch systemd override missing"

# ─── 10. TLS Certificates ─────────────────────────────────────
section "10. TLS Certificates (Phase 2)"
CERT="/etc/elasticsearch/certs/elastic-certificates.p12"
if [ -f "$CERT" ]; then
    pass "TLS cert exists: $CERT"
    CERT_OWNER=$(stat -c '%U' "$CERT" 2>/dev/null)
    [ "$CERT_OWNER" == "elasticsearch" ] && pass "Cert owned by 'elasticsearch'" || fail "Cert owned by '$CERT_OWNER' (expected: elasticsearch)"
    CERT_PERM=$(stat -c '%a' "$CERT" 2>/dev/null)
    [ "$CERT_PERM" == "640" ] && pass "Cert permissions = 640" || warn "Cert permissions = $CERT_PERM (recommended: 640)"
else
    warn "TLS cert not yet in place — generate with elasticsearch-certutil (Phase 2a)"
fi

# ─── 11. Keystore ─────────────────────────────────────────────
section "11. Elasticsearch Keystore (Phase 2b)"
if [ -f "/etc/elasticsearch/elasticsearch.keystore" ]; then
    KEYSTORE_ENTRIES=$(sudo /usr/share/elasticsearch/bin/elasticsearch-keystore list 2>/dev/null)

    # CRITICAL FIX: http.ssl entries must NOT be in keystore
    # ES 8.x installer auto-adds these during dnf install — they cause startup
    # failure when http.ssl is not configured in elasticsearch.yml
    if echo "$KEYSTORE_ENTRIES" | grep -q "http.ssl"; then
        fail "http.ssl entries found in keystore — MUST remove them:
        for key in \$(sudo /usr/share/elasticsearch/bin/elasticsearch-keystore list | grep ssl); do
          sudo /usr/share/elasticsearch/bin/elasticsearch-keystore remove \"\$key\"
        done"
    else
        pass "No http.ssl entries in keystore (correct)"
    fi

    echo "$KEYSTORE_ENTRIES" | grep -q "xpack.security.transport.ssl.keystore.secure_password" \
        && pass "transport.ssl.keystore.secure_password set in keystore" \
        || warn "transport.ssl.keystore.secure_password not in keystore (set after cert generation)"

    echo "$KEYSTORE_ENTRIES" | grep -q "xpack.security.transport.ssl.truststore.secure_password" \
        && pass "transport.ssl.truststore.secure_password set in keystore" \
        || warn "transport.ssl.truststore.secure_password not in keystore (set after cert generation)"
else
    warn "Keystore not found — will be created when elasticsearch-keystore is run (Phase 2b)"
fi

# ─── 12. Elasticsearch Cluster Health (Phase 2e+) ─────────────
section "12. Elasticsearch Cluster Health (Phase 2e onwards)"
if [ "$(systemctl is-active elasticsearch 2>/dev/null)" == "active" ]; then
    HEALTH=$(curl -sf http://localhost:9200/_cluster/health 2>/dev/null)
    if [ -n "$HEALTH" ]; then
        STATUS=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)
        NODES=$(echo "$HEALTH"  | python3 -c "import sys,json; print(json.load(sys.stdin)['number_of_nodes'])" 2>/dev/null)
        case "$STATUS" in
            green)  pass "Cluster status = green ($NODES nodes)" ;;
            yellow) warn "Cluster status = yellow ($NODES nodes) — check unassigned shards" ;;
            red)    fail "Cluster status = red ($NODES nodes) — check ES logs" ;;
            *)      warn "Cluster status = unknown (curl may need -u elastic:PASSWORD)" ;;
        esac
        [ "${NODES:-0}" -eq 3 ] && pass "All 3 nodes in cluster" || warn "Only $NODES node(s) found (expected 3)"
    else
        fail "Could not reach Elasticsearch on port 9200 — check: sudo journalctl -u elasticsearch -n 50"
    fi
else
    warn "Elasticsearch not running — skip cluster health check (start after TLS setup)"
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
