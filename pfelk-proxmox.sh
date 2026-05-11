#!/usr/bin/env bash
# =============================================================================
#  pfelk-proxmox.sh — Single-file pfelk LXC installer for Proxmox VE
#
#  Upload to your Proxmox host, then:
#    bash pfelk-proxmox.sh
#
#  Creates an Ubuntu 24.04 LXC container (4 vCPU / 8 GB RAM / 32 GB disk)
#  and installs the full pfelk ELK 9.x security stack inside it.
#  OPNsense/Suricata syslog target: <container-ip>:5140
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
#  HOST SECTION — runs on the Proxmox VE host
# ──────────────────────────────────────────────────────────────────────────────

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; BL="\033[36m"; CL="\033[m"
BFR="\\r\\033[K"; HOLD="  "

msg_info()  { printf " ${HOLD}${YW}${1}...${CL}"; }
msg_ok()    { printf "${BFR} ${GN}✓${CL} ${1}\n"; }
msg_error() { printf "${BFR} ${RD}✗${CL} ${1}\n"; exit 1; }

clear
cat << 'BANNER'

  ██████╗ ███████╗███████╗██╗     ██╗  ██╗
  ██╔══██╗██╔════╝██╔════╝██║     ██║ ██╔╝
  ██████╔╝█████╗  █████╗  ██║     █████╔╝
  ██╔═══╝ ██╔══╝  ██╔══╝  ██║     ██╔═██╗
  ██║     ██║     ███████╗███████╗██║  ██╗
  ╚═╝     ╚═╝     ╚══════╝╚══════╝╚═╝  ╚═╝

  ELK Security Stack for OPNsense · Suricata · Unbound
  Proxmox VE LXC Installer  —  ELK 9.x / Ubuntu 24.04

BANNER

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]           && msg_error "Must run as root on the Proxmox host"
command -v pct   &>/dev/null || msg_error "pct not found — is this a Proxmox VE host?"
command -v pvesm &>/dev/null || msg_error "pvesm not found — is this a Proxmox VE host?"
command -v pveam &>/dev/null || msg_error "pveam not found — is this a Proxmox VE host?"

# ── Storage detection ─────────────────────────────────────────────────────────
msg_info "Detecting storage pools"

# Template storage: prefer 'local', else first available
if pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "local"; then
  TEMPLATE_STORAGE="local"
else
  TEMPLATE_STORAGE=$(pvesm status 2>/dev/null | awk 'NR>1{print $1; exit}')
fi

# Disk storage: prefer local-lvm, then local-zfs, then first available
if pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "local-lvm"; then
  DISK_STORAGE="local-lvm"
elif pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "local-zfs"; then
  DISK_STORAGE="local-zfs"
else
  DISK_STORAGE=$(pvesm status 2>/dev/null | awk 'NR>1{print $1; exit}')
fi

[[ -z "${TEMPLATE_STORAGE:-}" ]] && msg_error "No storage found"
[[ -z "${DISK_STORAGE:-}"     ]] && msg_error "No disk storage found"

msg_ok "Template: ${TEMPLATE_STORAGE}  Disk: ${DISK_STORAGE}"

# ── Ubuntu 24.04 template ─────────────────────────────────────────────────────
msg_info "Locating Ubuntu 24.04 template"

TEMPLATE_NAME=$(pveam available --section system 2>/dev/null \
  | awk '{print $2}' | grep "ubuntu-24.04" | sort -V | tail -1 || true)

if [[ -z "${TEMPLATE_NAME:-}" ]]; then
  TEMPLATE_NAME="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  printf "${BFR} ${YW}⚠${CL} pveam list unavailable, using known name: ${TEMPLATE_NAME}\n"
else
  msg_ok "Found template: ${TEMPLATE_NAME}"
fi

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "${TEMPLATE_NAME%%_*}"; then
  msg_info "Downloading ${TEMPLATE_NAME}"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" \
    || msg_error "Template download failed"
  msg_ok "Downloaded ${TEMPLATE_NAME}"
else
  msg_ok "Template already present"
fi

TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

# ── Container identity ────────────────────────────────────────────────────────
CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
ROOT_PASS=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)

# ── Create container ──────────────────────────────────────────────────────────
msg_info "Creating LXC container ${CTID}"

pct create "$CTID" "$TEMPLATE_PATH" \
  --arch        amd64 \
  --ostype      ubuntu \
  --hostname    pfelk \
  --cores       4 \
  --memory      8192 \
  --swap        512 \
  --rootfs      "${DISK_STORAGE}:32" \
  --net0        "name=eth0,bridge=vmbr0,ip=dhcp,ip6=auto,firewall=0" \
  --unprivileged 1 \
  --features    "nesting=1" \
  --password    "$ROOT_PASS" \
  --start       0 \
  --timezone    host \
  2>/dev/null \
  || msg_error "pct create failed"

# Inject vm.max_map_count before start (required for Elasticsearch in LXC)
echo "lxc.sysctl.vm.max_map_count = 262144" >> "/etc/pve/lxc/${CTID}.conf"

msg_ok "Container ${CTID} created"

# ── Start container ───────────────────────────────────────────────────────────
msg_info "Starting container"
pct start "$CTID" || msg_error "pct start failed"

# Wait for container shell to become available
for i in $(seq 1 30); do
  pct exec "$CTID" -- true 2>/dev/null && break
  sleep 2
done

# Wait for IP address
msg_info "Waiting for network"
CT_IP=""
for i in $(seq 1 30); do
  CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$CT_IP" ]] && break
  sleep 2
done
[[ -z "$CT_IP" ]] && printf "${BFR} ${YW}⚠${CL} Could not detect IP — continuing\n" \
                   || msg_ok "Container IP: ${CT_IP}"

# ──────────────────────────────────────────────────────────────────────────────
#  EMBEDDED INSTALL SCRIPT — everything below runs inside the container
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Writing install script"
TMPSCRIPT=$(mktemp /tmp/pfelk-install-XXXXXX.sh)

cat > "$TMPSCRIPT" << 'CONTAINER_SCRIPT'
#!/usr/bin/env bash
# pfelk install — runs inside the LXC container (no community-scripts dependency)
set -euo pipefail

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
BFR="\\r\\033[K"; HOLD="  "
msg_info() { printf " ${HOLD}${YW}${1}...${CL}"; }
msg_ok()   { printf "${BFR} ${GN}✓${CL} ${1}\n"; }
msg_error(){ printf "${BFR} ${RD}✗${CL} ${1}\n"; exit 1; }

# ── Passwords (generated at install time) ────────────────────────────────────
ELASTIC_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
KIBANA_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
LOGSTASH_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
KB_ENC_KEY=$(openssl rand -hex 16)

# ── System preparation ────────────────────────────────────────────────────────
msg_info "Preparing system"
swapoff -a 2>/dev/null || true
sed -i '/swap/d' /etc/fstab 2>/dev/null || true
sysctl -w vm.max_map_count=262144 2>/dev/null \
  || echo 262144 > /proc/sys/vm/max_map_count 2>/dev/null || true
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-pfelk.conf
timedatectl set-timezone UTC 2>/dev/null || true
msg_ok "System prepared"

# ── Prerequisites ─────────────────────────────────────────────────────────────
msg_info "Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>/dev/null
apt-get install -y -qq --no-install-recommends \
  curl gnupg apt-transport-https ca-certificates lsb-release jq 2>/dev/null
msg_ok "Prerequisites installed"

# ── Elastic 9.x repository ───────────────────────────────────────────────────
msg_info "Adding Elastic 9.x repository"
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

cat > /etc/apt/sources.list.d/elastic-9.x.sources << 'REPO_EOF'
Types: deb
URIs: https://artifacts.elastic.co/packages/9.x/apt
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/elasticsearch-keyring.gpg
REPO_EOF

apt-get update -qq 2>/dev/null
msg_ok "Elastic repository added"

# ── Install ELK stack ─────────────────────────────────────────────────────────
msg_info "Installing Elasticsearch, Logstash, Kibana (this takes several minutes)"
apt-get install -y -qq --no-install-recommends \
  elasticsearch logstash kibana 2>/dev/null
msg_ok "ELK stack installed"

# ── JVM heap sizing (half of RAM, capped at 31 GB) ────────────────────────────
TOTAL_MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
HEAP_MB=$((TOTAL_MEM_MB / 2))
[[ $HEAP_MB -gt 31744 ]] && HEAP_MB=31744
[[ $HEAP_MB -lt 512   ]] && HEAP_MB=512
LS_HEAP_MB=$((HEAP_MB / 2))
[[ $LS_HEAP_MB -lt 512 ]] && LS_HEAP_MB=512

# ── Configure Elasticsearch ───────────────────────────────────────────────────
msg_info "Configuring Elasticsearch"

cat > /etc/elasticsearch/elasticsearch.yml << 'ES_EOF'
cluster.name: pfelk
node.name: pfelk-node-1
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node
bootstrap.memory_lock: false
xpack.security.enabled: true
xpack.security.http.ssl:
  enabled: true
  keystore.path: certs/http.p12
xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  keystore.path: certs/transport.p12
  truststore.path: certs/transport.p12
ES_EOF

sed -i "s/-Xms[0-9]*[mg]/-Xms${HEAP_MB}m/g" /etc/elasticsearch/jvm.options
sed -i "s/-Xmx[0-9]*[mg]/-Xmx${HEAP_MB}m/g" /etc/elasticsearch/jvm.options

msg_ok "Elasticsearch configured (heap: ${HEAP_MB} MB)"

# ── Configure Logstash ────────────────────────────────────────────────────────
msg_info "Configuring Logstash"

cat > /etc/logstash/logstash.yml << 'LS_EOF'
path.data: /var/lib/logstash
path.logs: /var/log/logstash
pipeline.workers: 2
pipeline.batch.size: 125
pipeline.batch.delay: 50
config.reload.automatic: false
LS_EOF

cat > /etc/logstash/pipelines.yml << 'LP_EOF'
- pipeline.id: pfelk
  path.config: "/etc/pfelk/conf.d/*.pfelk"
  pipeline.workers: 2
LP_EOF

sed -i "s/-Xms[0-9]*[mg]/-Xms${LS_HEAP_MB}m/g" /etc/logstash/jvm.options 2>/dev/null || true
sed -i "s/-Xmx[0-9]*[mg]/-Xmx${LS_HEAP_MB}m/g" /etc/logstash/jvm.options 2>/dev/null || true

# Environment file for pipeline variable substitution (${ELASTIC_PASSWORD} in 50-outputs.pfelk)
mkdir -p /etc/logstash
cat > /etc/logstash/elk-secrets.env << SECRETS_EOF
ELASTIC_PASSWORD=${LOGSTASH_PASSWORD}
SECRETS_EOF
chmod 600 /etc/logstash/elk-secrets.env
chown root:logstash /etc/logstash/elk-secrets.env 2>/dev/null || true

mkdir -p /etc/systemd/system/logstash.service.d
cat > /etc/systemd/system/logstash.service.d/env.conf << 'SYSD_EOF'
[Service]
EnvironmentFile=/etc/logstash/elk-secrets.env
SYSD_EOF
systemctl daemon-reload

msg_ok "Logstash configured (heap: ${LS_HEAP_MB} MB)"

# ── Configure Kibana ──────────────────────────────────────────────────────────
msg_info "Configuring Kibana"

cat > /etc/kibana/kibana.yml << KB_EOF
server.host: "0.0.0.0"
server.port: 5601
server.name: "pfelk"
elasticsearch.hosts: ["https://localhost:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_PASSWORD}"
elasticsearch.ssl.certificateAuthorities: ["/etc/pfelk/config/certs/http_ca.crt"]
xpack.security.encryptionKey: "${KB_ENC_KEY}"
xpack.encryptedSavedObjects.encryptionKey: "${KB_ENC_KEY}"
xpack.reporting.encryptionKey: "${KB_ENC_KEY}"
logging.appenders.default.type: console
logging.root.level: warn
KB_EOF

msg_ok "Kibana configured"

# ── pfelk directory structure ─────────────────────────────────────────────────
msg_info "Creating pfelk directory structure"
mkdir -p /etc/pfelk/{conf.d,patterns,databases,config/certs}
msg_ok "pfelk directories created"

# ── Grok patterns ─────────────────────────────────────────────────────────────
msg_info "Writing grok patterns"

cat > /etc/pfelk/patterns/pfelk.grok << 'GROK_EOF'
# pfelk grok pattern library
PFELK_SYSLOG5424 <%{NONNEGINT:[log][syslog][priority]}>%{NONNEGINT:[log][syslog][version]} (?:%{TIMESTAMP_ISO8601:[log][syslog][timestamp]}|-) (?:%{HOSTNAME:[log][syslog][hostname]}|-) (?:%{NOTSPACE:[log][syslog][appname]}|-) (?:%{NOTSPACE:[log][syslog][procid]}|-) (?:%{NOTSPACE:[log][syslog][msgid]}|-) (?:\[%{GREEDYDATA:[log][syslog][structured_data]}\]|-) %{GREEDYDATA:pfelk}
PFELK_SYSLOG3164 <%{NONNEGINT:[log][syslog][priority]}>%{SYSLOGTIMESTAMP:[log][syslog][timestamp]} %{HOSTNAME:[log][syslog][hostname]} %{NOTSPACE:[log][syslog][appname]}(?:\[%{POSINT:[log][syslog][procid]}\])?: %{GREEDYDATA:pfelk}
PFELK (?:%{PFELK_SYSLOG5424}|%{PFELK_SYSLOG3164})
GROK_EOF

msg_ok "Grok patterns written"

# ── Pipeline: 01-inputs.pfelk ─────────────────────────────────────────────────
msg_info "Writing pipeline files"

cat > /etc/pfelk/conf.d/01-inputs.pfelk << 'PIPE_EOF'
input {
  syslog {
    port          => 5140
    type          => "syslog"
    tags          => [ "pfelk" ]
    grok_pattern  => "<%{NONNEGINT:[log][syslog][priority]}>%{GREEDYDATA:pfelk}"
  }
}

filter {
  if "pfelk" in [tags] {
    grok {
      match => { "pfelk" => [
        "%{NONNEGINT:[log][syslog][version]} %{TIMESTAMP_ISO8601:[log][syslog][timestamp]} %{HOSTNAME:[log][syslog][hostname]} %{NOTSPACE:[log][syslog][appname]} %{NOTSPACE:[log][syslog][procid]} %{NOTSPACE:[log][syslog][msgid]} (?:\[%{GREEDYDATA:[log][syslog][structured_data]}\]|-) %{GREEDYDATA:pfelk}",
        "%{SYSLOGTIMESTAMP:[log][syslog][timestamp]} %{HOSTNAME:[log][syslog][hostname]} %{NOTSPACE:[log][syslog][appname]}(?:\[%{POSINT:[log][syslog][procid]}\])?: %{GREEDYDATA:pfelk}"
      ] }
      patterns_dir => [ "/etc/pfelk/patterns" ]
      add_tag      => [ "pfelk_parsed" ]
      tag_on_failure => [ "_pfelk_grok_failure" ]
    }
    date {
      match  => [ "[log][syslog][timestamp]", "ISO8601", "MMM dd HH:mm:ss", "MMM  d HH:mm:ss" ]
      target => "@timestamp"
    }
    mutate {
      copy => { "[log][syslog][hostname]" => "[host][name]" }
    }
  }
}
PIPE_EOF

# ── Pipeline: 02-firewall.pfelk ───────────────────────────────────────────────
cat > /etc/pfelk/conf.d/02-firewall.pfelk << 'PIPE_EOF'
filter {
  if "pfelk" in [tags] and [log][syslog][appname] == "filterlog" {
    mutate { add_tag => [ "pfelk_firewall" ] }

    csv {
      source    => "pfelk"
      target    => "pfelk_csv"
      separator => ","
    }

    # Detect IP version by field count (IPv4 ≥ 21 cols, IPv6 = 15 cols)
    ruby {
      code => '
        csv = event.get("pfelk_csv")
        if csv.is_a?(Hash)
          event.set("[@metadata][ipver]", csv.length >= 21 ? "4" : "6")
        end
      '
    }

    if [@metadata][ipver] == "4" {
      mutate {
        rename => {
          "[pfelk_csv][column1]"  => "[event][id]"
          "[pfelk_csv][column2]"  => "[network][vlan][id]"
          "[pfelk_csv][column3]"  => "[observer][ingress][interface][name]"
          "[pfelk_csv][column5]"  => "[rule][ruleset]"
          "[pfelk_csv][column6]"  => "[rule][id]"
          "[pfelk_csv][column7]"  => "[event][action]"
          "[pfelk_csv][column8]"  => "[network][direction]"
          "[pfelk_csv][column10]" => "[network][iana_number]"
          "[pfelk_csv][column11]" => "[network][transport]"
          "[pfelk_csv][column13]" => "[source][ip]"
          "[pfelk_csv][column14]" => "[destination][ip]"
          "[pfelk_csv][column17]" => "[source][port]"
          "[pfelk_csv][column18]" => "[destination][port]"
          "[pfelk_csv][column19]" => "[network][bytes]"
        }
      }
    } else if [@metadata][ipver] == "6" {
      mutate {
        rename => {
          "[pfelk_csv][column1]"  => "[event][id]"
          "[pfelk_csv][column2]"  => "[network][vlan][id]"
          "[pfelk_csv][column3]"  => "[observer][ingress][interface][name]"
          "[pfelk_csv][column5]"  => "[rule][ruleset]"
          "[pfelk_csv][column6]"  => "[rule][id]"
          "[pfelk_csv][column7]"  => "[event][action]"
          "[pfelk_csv][column8]"  => "[network][direction]"
          "[pfelk_csv][column10]" => "[network][iana_number]"
          "[pfelk_csv][column11]" => "[network][transport]"
          "[pfelk_csv][column13]" => "[source][ip]"
          "[pfelk_csv][column14]" => "[destination][ip]"
          "[pfelk_csv][column17]" => "[source][port]"
          "[pfelk_csv][column18]" => "[destination][port]"
        }
      }
    }

    if [network][direction] == "in"  { mutate { update => { "[network][direction]" => "ingress" } } }
    if [network][direction] == "out" { mutate { update => { "[network][direction]" => "egress"  } } }

    if [event][action] == "pass"  { mutate { add_field => { "[event][type]" => "allowed" } } }
    if [event][action] == "block" { mutate { add_field => { "[event][type]" => "denied"  } } }

    mutate {
      add_field => {
        "[event][category]"             => "network"
        "[event][kind]"                 => "event"
        "[event][dataset]"              => "pfelk.firewall"
        "[@metadata][pfelk_namespace]"  => "firewall"
      }
      remove_field => [ "pfelk_csv" ]
    }
  }
}
PIPE_EOF

# ── Pipeline: 05-apps.pfelk ───────────────────────────────────────────────────
cat > /etc/pfelk/conf.d/05-apps.pfelk << 'PIPE_EOF'
filter {
  if "pfelk" in [tags] {

    # ── Suricata (EVE JSON delivered via OPNsense syslog) ─────────────────────
    if [log][syslog][appname] == "suricata" {
      json {
        source  => "pfelk"
        target  => "suricata"
        add_tag => [ "pfelk_suricata" ]
      }
      if "_jsonparsefailure" not in [tags] {
        if [suricata][src_ip]    { mutate { copy => { "[suricata][src_ip]"    => "[source][ip]"           } } }
        if [suricata][dest_ip]   { mutate { copy => { "[suricata][dest_ip]"   => "[destination][ip]"      } } }
        if [suricata][src_port]  { mutate { copy => { "[suricata][src_port]"  => "[source][port]"         } } }
        if [suricata][dest_port] { mutate { copy => { "[suricata][dest_port]" => "[destination][port]"    } } }
        if [suricata][proto]     { mutate { copy => { "[suricata][proto]"     => "[network][transport]"   } } }
        if [suricata][alert][signature] {
          mutate { copy => { "[suricata][alert][signature]" => "[rule][name]" } }
        }
        if [suricata][alert][severity] {
          mutate { copy => { "[suricata][alert][severity]" => "[event][severity]" } }
        }
        mutate {
          add_field => {
            "[event][kind]"                => "alert"
            "[event][category]"            => "intrusion_detection"
            "[event][dataset]"             => "pfelk.suricata"
            "[@metadata][pfelk_namespace]" => "suricata"
          }
        }
      }
    }

    # ── Unbound DNS ───────────────────────────────────────────────────────────
    if [log][syslog][appname] == "unbound" {
      grok {
        match      => { "pfelk" => "%{WORD:[dns][type]} %{HOSTNAME:[dns][question][name]} %{WORD:[dns][question][class]} %{WORD:[dns][question][type]}" }
        tag_on_failure => []
      }
      mutate {
        add_field => {
          "[event][category]"            => "network"
          "[event][kind]"                => "event"
          "[event][dataset]"             => "pfelk.unbound"
          "[@metadata][pfelk_namespace]" => "unbound"
        }
      }
    }

    # ── DHCP ─────────────────────────────────────────────────────────────────
    if [log][syslog][appname] =~ /^dhcp/ {
      mutate {
        add_field => {
          "[event][category]"            => "network"
          "[event][kind]"                => "event"
          "[event][dataset]"             => "pfelk.dhcp"
          "[@metadata][pfelk_namespace]" => "dhcp"
        }
      }
    }

    # ── OpenVPN ───────────────────────────────────────────────────────────────
    if [log][syslog][appname] == "openvpn" {
      mutate {
        add_field => {
          "[event][category]"            => "network"
          "[event][kind]"                => "event"
          "[event][dataset]"             => "pfelk.openvpn"
          "[@metadata][pfelk_namespace]" => "openvpn"
        }
      }
    }

    # ── HAProxy ───────────────────────────────────────────────────────────────
    if [log][syslog][appname] == "haproxy" {
      mutate {
        add_field => {
          "[event][dataset]"             => "pfelk.haproxy"
          "[@metadata][pfelk_namespace]" => "haproxy"
        }
      }
    }

    # ── Default namespace ─────────────────────────────────────────────────────
    if ![@metadata][pfelk_namespace] {
      mutate { add_field => { "[@metadata][pfelk_namespace]" => "syslog" } }
    }

  }
}
PIPE_EOF

# ── Pipeline: 30-geoip.pfelk ──────────────────────────────────────────────────
cat > /etc/pfelk/conf.d/30-geoip.pfelk << 'PIPE_EOF'
filter {
  if "pfelk" in [tags] {

    if [source][ip] {
      cidr {
        address => [ "%{[source][ip]}" ]
        network => [ "10.0.0.0/8","172.16.0.0/12","192.168.0.0/16",
                     "127.0.0.0/8","169.254.0.0/16","::1/128","fc00::/7","fe80::/10" ]
        add_tag => [ "_src_private" ]
      }
      if "_src_private" not in [tags] {
        geoip {
          source => "[source][ip]"
          target => "[source][geo]"
          fields => [ "city_name","country_name","country_code2","location","region_name" ]
        }
        geoip {
          source                => "[source][ip]"
          target                => "[source][as]"
          default_database_type => "ASN"
          fields                => [ "autonomous_system_number","autonomous_system_organization" ]
        }
      }
    }

    if [destination][ip] {
      cidr {
        address => [ "%{[destination][ip]}" ]
        network => [ "10.0.0.0/8","172.16.0.0/12","192.168.0.0/16",
                     "127.0.0.0/8","169.254.0.0/16","::1/128","fc00::/7","fe80::/10" ]
        add_tag => [ "_dst_private" ]
      }
      if "_dst_private" not in [tags] {
        geoip {
          source => "[destination][ip]"
          target => "[destination][geo]"
          fields => [ "city_name","country_name","country_code2","location","region_name" ]
        }
        geoip {
          source                => "[destination][ip]"
          target                => "[destination][as]"
          default_database_type => "ASN"
          fields                => [ "autonomous_system_number","autonomous_system_organization" ]
        }
      }
    }

    mutate { remove_tag => [ "_src_private", "_dst_private" ] }
  }
}
PIPE_EOF

# ── Pipeline: 49-cleanup.pfelk ────────────────────────────────────────────────
cat > /etc/pfelk/conf.d/49-cleanup.pfelk << 'PIPE_EOF'
filter {
  if "pfelk" in [tags] {
    mutate {
      rename => { "message" => "[event][original]" }
      remove_field => [
        "pfelk", "timestamp8601", "logsource", "facility", "facility_label",
        "severity", "severity_label", "priority", "pid", "host6"
      ]
      add_field => { "[ecs][version]" => "8.11.0" }
    }
    if ![event][created] {
      mutate { copy => { "@timestamp" => "[event][created]" } }
    }
  }
}
PIPE_EOF

# ── Pipeline: 50-outputs.pfelk ────────────────────────────────────────────────
# NOTE: ${ELASTIC_PASSWORD} is intentionally literal — Logstash substitutes it
#       at runtime from /etc/logstash/elk-secrets.env via the systemd EnvironmentFile.
cat > /etc/pfelk/conf.d/50-outputs.pfelk << 'PIPE_EOF'
output {
  if "pfelk" in [tags] {
    elasticsearch {
      hosts                       => ["https://localhost:9200"]
      user                        => "logstash_writer"
      password                    => "${ELASTIC_PASSWORD}"
      ssl_enabled                 => true
      ssl_certificate_authorities => ["/etc/pfelk/config/certs/http_ca.crt"]
      data_stream                 => true
      data_stream_type            => "logs"
      data_stream_dataset         => "pfelk.%{[@metadata][pfelk_namespace]}"
      data_stream_namespace       => "default"
    }
  }
}
PIPE_EOF

msg_ok "Pipeline files written"

# Set ownership so Logstash can read
chown -R root:logstash /etc/pfelk/ 2>/dev/null || true
chmod -R 750 /etc/pfelk/ 2>/dev/null || true

# ── Start Elasticsearch ───────────────────────────────────────────────────────
msg_info "Starting Elasticsearch"
systemctl enable -q --now elasticsearch

# Wait for TLS cert to appear (generated on first boot)
for i in $(seq 1 20); do
  [[ -f /etc/elasticsearch/certs/http_ca.crt ]] && break
  sleep 3
done

# Wait for HTTP API (401 = auth required = ES is running)
for i in $(seq 1 50); do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    --cacert /etc/elasticsearch/certs/http_ca.crt \
    "https://localhost:9200/" 2>/dev/null || echo "000")
  [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "200" ]] && break
  sleep 3
done

msg_ok "Elasticsearch started"

# ── Copy CA cert ──────────────────────────────────────────────────────────────
cp /etc/elasticsearch/certs/http_ca.crt /etc/pfelk/config/certs/
chown root:logstash /etc/pfelk/config/certs/http_ca.crt 2>/dev/null || true
chmod 640 /etc/pfelk/config/certs/http_ca.crt

# ── Set Elasticsearch passwords ───────────────────────────────────────────────
msg_info "Setting Elasticsearch passwords"

ES_CACERT="--cacert /etc/elasticsearch/certs/http_ca.crt"
ES_URL="https://localhost:9200"

# Reset elastic to get a known bootstrap password, then set our desired one
RESET_OUT=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u elastic --batch 2>&1 || true)
BOOT_PASS=$(echo "$RESET_OUT" | awk '/New value:/{print $NF}')

if [[ -z "$BOOT_PASS" ]]; then
  # Fallback: try parsing different output format
  BOOT_PASS=$(echo "$RESET_OUT" | grep -oP '(?<=New value: )\S+' || true)
fi

# Set elastic to our generated password
curl -sk $ES_CACERT -X PUT "${ES_URL}/_security/user/elastic/_password" \
  -u "elastic:${BOOT_PASS}" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${ELASTIC_PASSWORD}\"}" >/dev/null

# kibana_system password
curl -sk $ES_CACERT -X PUT "${ES_URL}/_security/user/kibana_system/_password" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${KIBANA_PASSWORD}\"}" >/dev/null &

# logstash_writer role
curl -sk $ES_CACERT -X PUT "${ES_URL}/_security/role/logstash_writer" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{
    "cluster": ["manage_index_templates","monitor","manage_ilm",
                "manage_ingest_pipelines","manage_pipeline"],
    "indices": [{
      "names":      ["logs-pfelk.*","metrics-pfelk.*","traces-pfelk.*"],
      "privileges": ["write","create","create_index","manage","auto_configure"]
    }]
  }' >/dev/null &

wait

# logstash_writer user (depends on role creation above completing)
curl -sk $ES_CACERT -X PUT "${ES_URL}/_security/user/logstash_writer" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d "{
    \"password\": \"${LOGSTASH_PASSWORD}\",
    \"roles\":    [\"logstash_writer\"],
    \"full_name\": \"pfelk Logstash Writer\"
  }" >/dev/null

msg_ok "Elasticsearch passwords set"

# ── Start Logstash and Kibana ─────────────────────────────────────────────────
msg_info "Starting Logstash and Kibana"
systemctl enable -q logstash kibana
systemctl start logstash &
systemctl start kibana &
wait
msg_ok "Logstash and Kibana starting"

# ── Wait for Kibana ───────────────────────────────────────────────────────────
msg_info "Waiting for Kibana (up to 5 min)"
for i in $(seq 1 60); do
  KB_LEVEL=$(curl -sk "http://localhost:5601/api/status" \
    -u "elastic:${ELASTIC_PASSWORD}" \
    -H "kbn-xsrf: true" 2>/dev/null \
    | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('status',{}).get('overall',{}).get('level',''))
except: print('')
" 2>/dev/null || true)
  [[ "$KB_LEVEL" == "available" ]] && break
  sleep 5
done
msg_ok "Kibana ready"

# ── Import pfelk dashboards ───────────────────────────────────────────────────
msg_info "Importing pfelk dashboards"

KB_AUTH="elastic:${ELASTIC_PASSWORD}"
KB_URL="http://localhost:5601"
GH_API="https://api.github.com/repos/pfelk/pfelk/contents/etc/pfelk/dashboard"
GH_RAW="https://raw.githubusercontent.com/pfelk/pfelk/main/etc/pfelk/dashboard"

# Fetch dashboard file list from GitHub API (latest files per topic)
NDJSON_FILES=$(curl -fsSL "$GH_API" 2>/dev/null \
  | python3 -c "
import sys, json, re
try:
    files = json.load(sys.stdin)
    names = [f['name'] for f in files if f['name'].endswith('.ndjson')]
    # deduplicate by topic: keep the lexicographically last (newest) per base name
    seen = {}
    for n in sorted(names):
        key = re.sub(r'[-_][0-9]+\\.ndjson$', '', n)
        seen[key] = n
    print('\\n'.join(seen.values()))
except Exception as e:
    pass
" 2>/dev/null || true)

# Fallback static list if GitHub API unavailable
if [[ -z "$NDJSON_FILES" ]]; then
  NDJSON_FILES="pfelk.ndjson
pfelk-firewall.ndjson
pfelk-suricata.ndjson
pfelk-unbound.ndjson
pfelk-dhcp.ndjson
pfelk-openvpn.ndjson
pfelk-haproxy.ndjson"
fi

IMPORTED=0
FAILED=0
while IFS= read -r dash; do
  [[ -z "$dash" ]] && continue
  TMP=$(mktemp /tmp/pfelk-dash-XXXXXX.ndjson)
  if curl -fsSL "${GH_RAW}/${dash}" -o "$TMP" 2>/dev/null && [[ -s "$TMP" ]]; then
    RESULT=$(curl -sk -X POST \
      "${KB_URL}/api/saved_objects/_import?overwrite=true" \
      -u "$KB_AUTH" \
      -H "kbn-xsrf: true" \
      -F "file=@${TMP}" 2>/dev/null || true)
    echo "$RESULT" | grep -q '"success":true' && IMPORTED=$((IMPORTED+1)) || FAILED=$((FAILED+1))
  else
    FAILED=$((FAILED+1))
  fi
  rm -f "$TMP"
done <<< "$NDJSON_FILES"

msg_ok "Dashboards imported (${IMPORTED} ok, ${FAILED} skipped)"

# ── Write credentials file ────────────────────────────────────────────────────
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

cat > /root/pfelk.creds << CREDS_EOF
╔══════════════════════════════════════════════════════╗
║               pfelk Credentials                     ║
╚══════════════════════════════════════════════════════╝

  Kibana URL       : http://${LOCAL_IP}:5601

  elastic user     : elastic
  elastic password : ${ELASTIC_PASSWORD}

  kibana_system    : kibana_system / ${KIBANA_PASSWORD}
  logstash_writer  : logstash_writer / ${LOGSTASH_PASSWORD}

  OPNsense Syslog  : ${LOCAL_IP}:5140  (UDP or TCP)
    → System > Log Files > Remote > Enable
    → Transport: UDP, Port: 5140, RFC5424

CREDS_EOF
chmod 600 /root/pfelk.creds

echo ""
echo "══════════════════════════════════════════════════════"
echo "  pfelk installation complete!"
echo "══════════════════════════════════════════════════════"
cat /root/pfelk.creds
echo "══════════════════════════════════════════════════════"

CONTAINER_SCRIPT

msg_ok "Install script ready"

# ── Push and run install script ───────────────────────────────────────────────
msg_info "Pushing install script to container ${CTID}"
pct push "$CTID" "$TMPSCRIPT" /root/pfelk-install.sh --perms 0700
rm -f "$TMPSCRIPT"
msg_ok "Install script pushed"

echo ""
echo -e " ${YW}Running pfelk install inside container ${CTID}...${CL}"
echo -e " ${YW}This will take 8–15 minutes. Live output follows:${CL}"
echo ""

pct exec "$CTID" -- bash /root/pfelk-install.sh

# ── Host-side completion banner ───────────────────────────────────────────────
echo ""
echo -e "${GN}╔══════════════════════════════════════════════════════╗${CL}"
echo -e "${GN}║        pfelk LXC Container Ready!                   ║${CL}"
echo -e "${GN}╚══════════════════════════════════════════════════════╝${CL}"
echo ""
echo -e "  Container ID    : ${BL}${CTID}${CL}"
echo -e "  Root password   : ${BL}${ROOT_PASS}${CL}"
echo -e "  Container IP    : ${BL}${CT_IP:-run: pct exec ${CTID} -- hostname -I}${CL}"
echo ""
echo -e "  Credentials file: ${BL}/root/pfelk.creds${CL}"
echo -e "  View with       : ${BL}pct exec ${CTID} -- cat /root/pfelk.creds${CL}"
echo ""
