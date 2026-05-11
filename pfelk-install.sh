#!/usr/bin/env bash

# Author: pfelk community
# License: MIT
# Source: https://github.com/pfelk/pfelk
# ELK 9.x + pfelk pipelines for OPNsense / Suricata

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Credentials (generated once, used everywhere)
# ══════════════════════════════════════════════════════════════════════════════
ELASTIC_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
KIBANA_PASSWORD=$(openssl rand -base64 18  | tr -d '/+=' | cut -c1-16)
LOGSTASH_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — System preparation
# ══════════════════════════════════════════════════════════════════════════════
msg_info "Preparing System"
# Disable swap (required by Elasticsearch)
swapoff -a 2>/dev/null || true
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# vm.max_map_count — Elasticsearch requires ≥262144
# In Proxmox LXC the host value is inherited; we try to raise it anyway
if sysctl -w vm.max_map_count=262144 &>/dev/null; then
  echo "vm.max_map_count=262144" > /etc/sysctl.d/99-elasticsearch.conf
else
  # Unprivileged container: write via procfs (works on most Proxmox versions)
  echo 262144 > /proc/sys/vm/max_map_count 2>/dev/null || true
fi
msg_ok "Prepared System"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Elastic APT repository + install all three services in ONE call
# ══════════════════════════════════════════════════════════════════════════════
msg_info "Setting up Elastic 9.x Repository"
setup_deb822_repo \
  "elasticsearch" \
  "https://artifacts.elastic.co/GPG-KEY-elasticsearch" \
  "https://artifacts.elastic.co/packages/9.x/apt" \
  "stable" \
  "main"
msg_ok "Set up Elastic Repository"

# Single apt-get call = one solver pass, one download phase — fastest approach
msg_info "Installing Elasticsearch, Logstash & Kibana"
$STD apt-get install -y --no-install-recommends \
  elasticsearch \
  logstash \
  kibana
msg_ok "Installed ELK Stack"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Configure all services in parallel before any service starts
#           (parallel writes shave ~2–3 s off sequential I/O)
# ══════════════════════════════════════════════════════════════════════════════
msg_info "Configuring ELK Stack"

# Auto-size JVM heap to half of container RAM, capped at 31 GB
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HEAP_MB=$(( TOTAL_MEM_KB / 1024 / 2 ))
(( HEAP_MB > 31744 )) && HEAP_MB=31744
HEAP="${HEAP_MB}m"

# ── pfelk directories ──────────────────────────────────────
mkdir -p /etc/pfelk/{conf.d,patterns,databases,config/certs}

# ── Elasticsearch ──────────────────────────────────────────
write_es_config() {
  cat > /etc/elasticsearch/elasticsearch.yml << 'EOF'
cluster.name: pfelk
node.name: pfelk-lxc
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node
# Memory locking is unreliable inside LXC; JVM heap sizing handles this instead
bootstrap.memory_lock: false
xpack.security.enabled: true
xpack.security.http.ssl.enabled: true
xpack.security.transport.ssl.enabled: true
xpack.license.self_generated.type: basic
xpack.monitoring.collection.enabled: true
EOF
  # Tune JVM heap (sed is safe here — file already written by package install)
  sed -i "s/-Xms[0-9]*[gGmM]/-Xms${HEAP}/" /etc/elasticsearch/jvm.options
  sed -i "s/-Xmx[0-9]*[gGmM]/-Xmx${HEAP}/" /etc/elasticsearch/jvm.options
}

# ── Logstash ───────────────────────────────────────────────
write_ls_config() {
  local ncpu; ncpu=$(nproc)
  cat > /etc/logstash/logstash.yml << EOF
node.name: pfelk-logstash
http.host: "127.0.0.1"
path.data: /var/lib/logstash
path.logs:  /var/log/logstash
pipeline.workers: ${ncpu}
pipeline.batch.size: 250
pipeline.batch.delay: 50
xpack.monitoring.enabled: true
xpack.monitoring.elasticsearch.hosts: ["https://localhost:9200"]
xpack.monitoring.elasticsearch.username: logstash_system
xpack.monitoring.elasticsearch.password: "${LOGSTASH_PASSWORD}"
xpack.monitoring.elasticsearch.ssl.certificate_authority: "/etc/pfelk/config/certs/http_ca.crt"
EOF

  cat > /etc/logstash/pipelines.yml << 'EOF'
- pipeline.id: pfelk
  path.config: "/etc/pfelk/conf.d/*.pfelk"
  pipeline.ecs_compatibility: v8
EOF

  # Secrets file — read by systemd EnvironmentFile= override
  cat > /etc/logstash/elk-secrets.env << EOF
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
LOGSTASH_PASSWORD=${LOGSTASH_PASSWORD}
EOF
  chmod 600 /etc/logstash/elk-secrets.env

  # Inject the env file into the logstash service
  mkdir -p /etc/systemd/system/logstash.service.d
  cat > /etc/systemd/system/logstash.service.d/override.conf << 'EOF'
[Service]
EnvironmentFile=/etc/logstash/elk-secrets.env
EOF
}

# ── Kibana ─────────────────────────────────────────────────
write_kb_config() {
  local enc_key; enc_key=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  cat > /etc/kibana/kibana.yml << EOF
server.port: 5601
server.host: "0.0.0.0"
server.name: "pfelk"
elasticsearch.hosts:
  - https://localhost:9200
elasticsearch.username: kibana_system
elasticsearch.password: "${KIBANA_PASSWORD}"
elasticsearch.ssl.certificateAuthorities: ["/etc/pfelk/config/certs/http_ca.crt"]
elasticsearch.ssl.verificationMode: "certificate"
xpack.security.enabled: true
xpack.encryptedSavedObjects.encryptionKey: "${enc_key}"
telemetry.enabled: false
EOF
}

# ── pfelk grok patterns ─────────────────────────────────────
write_grok_patterns() {
  cat > /etc/pfelk/patterns/pfelk.grok << 'EOF'
PFELK (%{PFSENSE}|%{OPNSENSE}|%{RFC5424})
PFSENSE %{SYSLOGTIMESTAMP:[event][created]}\s(%{SYSLOGHOST:[log][syslog][hostname]}\s)?%{PROG:[log][syslog][appname]}(\[%{POSINT:[log][syslog][procid]:int}\])?\:\s%{GREEDYDATA:filter_message}
OPNSENSE %{SYSLOGTIMESTAMP:[event][created]}\s%{SYSLOGHOST:[log][syslog][hostname]}\s%{PROG:[log][syslog][appname]}\[%{POSINT:[log][syslog][procid]}\]\:\s%{GREEDYDATA:filter_message}
RFC5424 (%{INT:[log][syslog][version]}\s*)%{TIMESTAMP_ISO8601:[event][created]}\s%{SYSLOGHOST:[log][syslog][hostname]}\s%{PROG:[log][syslog][appname]}(\s%{POSINT:[log][syslog][procid]})?(\s\-\s\-\s?(\-\s)?)?(\s\-\s\[meta\ssequenceId\=(\\")?"%{NUMBER:[event][sequence]}(\\")?"\])?\s%{GREEDYDATA:filter_message}
CAPTIVEPORTAL (%{CP_PFSENSE}|%{CP_OPNSENSE})
CP_OPNSENSE %{WORD:[event][action]}\s%{GREEDYDATA:[client][user][name]}\s\(%{IP:[client][ip]}\)\s%{WORD:[observer][ingress][interface][alias]}\s%{INT:[observer][ingress][zone]}
CP_PFSENSE (%{CAPTIVE1}|%{CAPTIVE2})
CAPTIVE1 %{WORD:[observer][ingress][interface][alias]}:\s%{DATA:[observer][ingress][zone]}\s\-\s%{WORD:[event][action]}\:\s%{GREEDYDATA:[client][user][name]},\s%{MAC:[client][mac]},\s%{IP:[client][ip]}(,\s%{GREEDYDATA:[event][reason]})?
CAPTIVE2 %{WORD:[observer][ingress][interface][alias]}:\s%{DATA:[observer][ingress][zone]}\s\-\s%{GREEDYDATA:[event][action]}\:\s%{GREEDYDATA:[client][user][name]},\s%{MAC:[client][mac]},\s%{IP:[client][ip]}(,\s%{GREEDYDATA:[event][reason]})?
DHCPD DHCP(%{DHCPD_DISCOVER}|%{DHCPD_DUPLICATE}|%{DHCPD_OFFER_ACK}|%{DHCPD_REQUEST}|%{DHCPD_DECLINE}|%{DHCPD_RELEASE}|%{DHCPD_INFORM}|%{DHCPD_LEASE})|%{DHCPD_REUSE}|%{DHCPDv6}|(%{GREEDYDATA:[DHCPD][message]})?
DHCPD_DISCOVER (?<[dhcp][operation]>DISCOVER) from %{MAC:[dhcpv4][client][mac]}( \(%{DATA:[dhcpv4][option][hostname]}\))? %{DHCPD_VIA}
DHCPD_DECLINE (?<[dhcp][operation]>DECLINE) of %{IP:[dhcpv4][client][ip]} from %{MAC:[dhcpv4][client][mac]}( \(%{DATA:[dhcpv4][option][hostname]}\))? %{DHCPD_VIA}
DHCPD_DUPLICATE uid %{WORD:[dhcp][operation]} %{IP:[dhcpv4][client][ip]} for client %{MAC:[dhcpv4][client][mac]} is %{WORD:[dhcp][error][code]} on %{GREEDYDATA:[dhcpv4][client][address]}
DHCPD_INFORM (?<[dhcp][operation]>INFORM) from %{IP:[dhcpv4][client][ip]}? %{DHCPD_VIA}
DHCPD_LEASE (?<[dhcp][operation]>LEASE(QUERY|UNKNOWN|ACTIVE|UNASSIGNED)) (from|to) %{IP:[dhcpv4][client][ip]} for (IP %{IP:[dhcpv4][query][ip]}|client-id %{NOTSPACE:[dhcpv4][query][id]}|MAC address %{MAC:[dhcpv4][query][mac]})( \(%{NUMBER:[dhcpv4][query][associated]} associated IPs\))?
DHCPD_OFFER_ACK (?<[dhcp][operation]>(OFFER|N?ACK)) on %{IP:[dhcpv4][client][ip]} to %{MAC:[dhcpv4][client][mac]}( \(%{DATA:[dhcpv4][option][hostname]}\))? %{DHCPD_VIA}
DHCPD_RELEASE (?<[dhcp][operation]>RELEASE) of %{IP:[dhcpv4][client][ip]} from %{MAC:[dhcpv4][client][mac]}( \(%{DATA:[dhcpv4][option][hostname]}\))? %{DHCPD_VIA} \((?<dhcpd_release>(not )?found)\)
DHCPD_REQUEST (?<[dhcp][operation]>REQUEST) for %{IP:[dhcpv4][client][ip]}( \(%{DATA:[dhcpv4][server][ip]}\))? from %{MAC:[dhcpv4][client][mac]}( \(%{DATA:[dhcpv4][option][hostname]}\))? %{DHCPD_VIA}
DHCPD_VIA via (%{IP:[dhcpv4][relay][ip]}|(?<[interface][name]>[^: ]+))
DHCPD_REUSE (?<[dhcpv4][operation]>reuse_lease): lease age %{INT:[dhcpv4][lease][duration]}.* lease for %{IPV4:[dhcpv4][client][ip]}
DHCPDv6 (%{DHCPv6_REPLY}|%{DHCPv6_ACTION}|%{DHCPv6_REUSE})
DHCPv6_REPLY (?<[dhcpv6][operation]>Advertise|Reply) NA: address %{IP:[dhcpv6][client][ip]} to client with duid %{GREEDYDATA:[dhcpv6][duid]}\siaid\s\=\s%{INT:[dhcpv6][iaid]} valid for %{INT:[dhcpv6][lease][duration]} seconds
DHCPv6_ACTION (?<[dhcpv6][operation]>(Request|Picking|Sending Reply|Sending Advertise|Confirm|Solicit|Renew))(\s)?(message)?(\s)?(to|from)?(\s)?(pool address)? %{IP:[dhcpv6][client][ip]}(\s)?(port %{INT:[dhcpv6][client][port]})?(, transaction ID %{BASE16FLOAT:[dhcpv6][transaction][id]})?
DHCPv6_REUSE (?<[dhcpv6][operation]>Reusing lease) for: %{IPV6:[dhcpv6][client][ip]}, age %{INT:[dhcpv6][lease][age][length]}.*preferred: %{INT:[dhcpv6][lease][age][preferred]}, valid %{INT:[dhcpv6][lease][age][valid]}
KEADHCP4 (%{KEADHCP_REBOOT}|%{KEADHCP_ADVERT}|%{KEADHCP_ALLOC}|%{KEADHCP_EXECUTE})
KEADHCP_REBOOT (?<[kea][dhcp][operation]>REBOOT)\s\[hwtype=%{INT:[kea][dhcp][hardware_type]}\s%{MAC:[kea][dhcp][client][mac]}\],\scid=\[%{GREEDYDATA:[kea][dhcp][id]}\]\,\stid=%{BASE16NUM:[kea][dhcp][lease][id]}.*(%{IPV4:[kea][dhcp][client][ip]}|%{IPV6:[kea][dhcp][client][ip]})
KEADHCP_ADVERT (?<[kea][dhcp][operation]>ADVERT)\s\[hwtype=%{INT:[kea][dhcp][hardware_type]}\s%{MAC:[kea][dhcp][client][mac]}\],\scid=\[%{GREEDYDATA:[kea][dhcp][id]}\]\,\stid=%{BASE16NUM:[kea][dhcp][lease][id]}\:\slease\s(%{IPV4:[kea][dhcp][client][ip]}|%{IPV6:[kea][dhcp][client][ip]})
KEADHCP_ALLOC (?<[kea][dhcp][operation]>ALLOC)\s\[hwtype=%{INT:[kea][dhcp][hardware_type]}\s%{MAC:[kea][dhcp][client][mac]}\],\scid=\[%{GREEDYDATA:[kea][dhcp][id]}\]\,\stid=%{BASE16NUM:[kea][dhcp][lease][id]}\:\slease\s(%{IPV4:[kea][dhcp][client][ip]}|%{IPV6:[kea][dhcp][client][ip]}).*%{NUMBER:[kea][dhcp][lease][duration]}
KEADHCP_EXECUTE (?<[kea][dhcp][operation]>EXECUTE)%{GREEDYDATA:[kea][message]}
KEADHCP6 %{GREEDYDATA:filter_message}
HAPROXY %{IP:[client][ip]}:%{INT:[client][port]:int} \[%{HAPROXYDATE:[haproxy][timestamp]}\] %{NOTSPACE:[haproxy][frontend_name]} %{NOTSPACE:[haproxy][backend_name]}/%{NOTSPACE:[haproxy][server_name]} %{INT:[haproxy][time_request]}/%{INT:[haproxy][time_queue]}/%{INT:[haproxy][time_backend_connect]:int}/%{INT:[haproxy][time_backend_response]:int}/%{NOTSPACE:[host][uptime]} %{INT:[http][response][status_code]:int} %{NOTSPACE:[haproxy][bytes_read]:int} %{DATA} %{DATA} %{NOTSPACE:[haproxy][termination_state]} %{INT:[haproxy][connections][active]:int}/%{INT:[haproxy][connections][frontend]:int}/%{INT:[haproxy][connections][backend]:int}/%{INT:[haproxy][connections][server]:int}/%{NOTSPACE:[haproxy][connections][retries]:int} %{INT:[haproxy][server_queue]:int}/%{INT:[haproxy][backend_queue]:int}.*
NGINX %{NGINX_META}%{NGINX_LOG}(%{NGINX_EXT})?
NGINX_META %{IPORHOST:[client][ip]}(\s\-\s)(%{USERNAME:[nginx][access][user_name]}|\-)?\ \[%{HTTPDATE:timestamp}\]\s*\"
NGINX_LOG %{WORD:[nginx][access][method]}\s*%{NOTSPACE:[nginx][access][url]}\s*HTTP/%{NUMBER:[nginx][access][http_version]}\"\ %{NUMBER:[nginx][access][response_code]}\ %{NUMBER:[nginx][access][body_sent][bytes]}\ "%{NOTSPACE:[nginx][access][referrer]}"\ "%{DATA:[nginx][access][agent]}"
NGINX_EXT (\s\"\ \-\"\s*)\ "%{IPORHOST:[nginx][access][forwarder]}".*
PF_APP (%{DATA:[pf][app][page]}):
PF_APP_DATA (%{PF_APP_LOGOUT}|%{PF_APP_LOGIN}|%{PF_APP_ERROR}|%{PF_APP_GEN})
PF_APP_LOGIN (%{DATA:[pf][app][action]}) for user \'(%{DATA:[pf][app][user]})\' from: (%{IP:[pf][remote][ip]})
PF_APP_LOGOUT User (%{DATA:[pf][app][action]}) for user \'(%{DATA:[pf][app][user]})\' from: (%{IP:[pf][remote][ip]})
PF_APP_ERROR webConfigurator (%{DATA:[pf][app][action]}) for user \'(%{DATA:[pf][app][user]})\' from (%{IP:[pf][remote][ip]})
PF_APP_GEN (%{GREEDYDATA:[pf][app][action]})
SURICATA (%{SURICATA_LOG}|%{SURICATA_NOTICE})
SURICATA_LOG \[%{NUMBER:[suricata][rule][uuid]}:%{NUMBER:[suricata][rule][id]}:%{NUMBER:[suricata][rule][version]}\]%{SPACE}%{GREEDYDATA:[suricata][rule][description]}%{SPACE}\[Classification:%{SPACE}%{GREEDYDATA:[suricata][rule][category]}\]%{SPACE}\[Priority:%{SPACE}%{NUMBER:[suricata][priority]}\]%{SPACE}{%{WORD:[network][transport]}}%{SPACE}%{IP:[source][ip]}:%{NUMBER:[source][port]}%{SPACE}->%{SPACE}%{IP:[destination][ip]}:%{NUMBER:[destination][port]}
SURICATA_NOTICE \[%{NUMBER:[event][code]}\]\s\<%{WORD:[event][action]}\>\s\-\-\s%{GREEDYDATA:[package][description]}
SNORT \[%{INT:[rule][uuid]}\:%{INT:[rule][reference]}\:%{INT:[rule][version]}\].%{GREEDYDATA:[vulnerability][description]}.\[Classification\: %{DATA:[vulnerability][classification]}\].\[Priority\: %{INT:[event][severity]}\].\{%{DATA:[network][transport]}\}.%{IP:[source][ip]}(\:%{INT:[source][port]})?.->.%{IP:[destination][ip]}(\:%{INT:[destination][port]})?
SQUID %{IPORHOST:[client][ip]} %{NOTSPACE:[labels][request_status]}/%{NUMBER:[http][response][body][status_code]} %{NUMBER:[http][response][bytes]} %{NOTSPACE:[http][request][method]} (%{URIPROTO:[url][scheme]}://)?(?<[url][domain]>\S+?)(:%{INT:[url][port]})?(/%{NOTSPACE:[url][path]})?\s+%{NOTSPACE:[http][request][referrer]}\s+%{NOTSPACE:[lables][hierarchy_status]}/%{NOTSPACE:[destination][address]}\s+%{NOTSPACE:[http][response][mime_type]}
UNBOUND %{INT:[process][pgid]}:%{INT:[process][thread][id]} %{LOGLEVEL:[log][level]}: %{IP:[client][ip]} %{GREEDYDATA:[dns][question][name]}\. %{WORD:[dns][question][type]} %{WORD:[dns][question][class]}
EOF
}

# ── Pipeline: 01-inputs ─────────────────────────────────────
write_pipeline_01() {
  cat > /etc/pfelk/conf.d/01-inputs.pfelk << 'EOF'
input {
  syslog {
    id => "pfelk-firewall-0001"
    type => "firewall"
    port => 5140
    syslog_field => "message"
    ecs_compatibility => v1
    grok_pattern => "<%{POSINT:[log][syslog][priority]}>%{GREEDYDATA:pfelk}"
    tags => ["pfelk"]
  }
}
filter {
  grok {
    patterns_dir => [ "/etc/pfelk/patterns" ]
    match => [ "pfelk", "%{PFELK}" ]
  }
  date {
    match => [ "[event][created]", "MMM  d HH:mm:ss", "MMM dd HH:mm:ss", "ISO8601" ]
    target => "[event][created]"
  }
}
EOF
}

# ── Pipeline: 02-firewall ───────────────────────────────────
write_pipeline_02() {
  cat > /etc/pfelk/conf.d/02-firewall.pfelk << 'EOF'
filter {
  if [log][syslog][appname] =~ /^filterlog$/ {
    mutate {
      add_tag => "firewall"
      add_field => { "[event][dataset]" => "pfelk.firewall" }
      replace => { "[log][syslog][appname]" => "firewall" }
      copy => { "filter_message" => "pfelk_csv" }
    }
    mutate {
      strip => "pfelk_csv"
      split => { "pfelk_csv" => "," }
    }
    mutate {
      add_field => {
        "[rule][id]"            => "%{[pfelk_csv][0]}"
        "[pf][rule][subid]"     => "%{[pfelk_csv][1]}"
        "[pf][anchor]"          => "%{[pfelk_csv][2]}"
        "[rule][uuid]"          => "%{[pfelk_csv][3]}"
        "[interface][name]"     => "%{[pfelk_csv][4]}"
        "[event][reason]"       => "%{[pfelk_csv][5]}"
        "[event][action]"       => "%{[pfelk_csv][6]}"
        "[network][direction]"  => "%{[pfelk_csv][7]}"
        "[network][type]"       => "%{[pfelk_csv][8]}"
      }
    }
    if [network][type] == "4" {
      mutate {
        add_field => {
          "[pf][tos]"               => "%{[pfelk_csv][9]}"
          "[pf][ecn]"               => "%{[pfelk_csv][10]}"
          "[pf][ttl]"               => "%{[pfelk_csv][11]}"
          "[pf][id]"                => "%{[pfelk_csv][12]}"
          "[pf][offset]"            => "%{[pfelk_csv][13]}"
          "[pf][flags]"             => "%{[pfelk_csv][14]}"
          "[network][iana_number]"  => "%{[pfelk_csv][15]}"
          "[network][protocol]"     => "%{[pfelk_csv][16]}"
          "[pf][packet][length]"    => "%{[pfelk_csv][17]}"
          "[source][ip]"            => "%{[pfelk_csv][18]}"
          "[destination][ip]"       => "%{[pfelk_csv][19]}"
        }
      }
      if [network][protocol] == "tcp" {
        mutate {
          add_field => {
            "[source][port]"              => "%{[pfelk_csv][20]}"
            "[destination][port]"         => "%{[pfelk_csv][21]}"
            "[pf][data_length]"           => "%{[pfelk_csv][22]}"
            "[pf][tcp][flags]"            => "%{[pfelk_csv][23]}"
            "[pf][tcp][sequence_number]"  => "%{[pfelk_csv][24]}"
            "[pf][tcp][ack]"              => "%{[pfelk_csv][25]}"
            "[pf][tcp][window]"           => "%{[pfelk_csv][26]}"
            "[pf][tcp][urg]"              => "%{[pfelk_csv][27]}"
            "[pf][tcp][options]"          => "%{[pfelk_csv][28]}"
          }
        }
      }
      if [network][protocol] == "udp" {
        mutate {
          add_field => {
            "[source][port]"      => "%{[pfelk_csv][20]}"
            "[destination][port]" => "%{[pfelk_csv][21]}"
            "[pf][data_length]"   => "%{[pfelk_csv][22]}"
          }
        }
      }
    }
    if [network][type] == "6" {
      mutate {
        add_field => {
          "[pf][class]"            => "%{[pfelk_csv][9]}"
          "[pf][flow]"             => "%{[pfelk_csv][10]}"
          "[pf][hoplimit]"         => "%{[pfelk_csv][11]}"
          "[network][protocol]"    => "%{[pfelk_csv][12]}"
          "[network][iana_number]" => "%{[pfelk_csv][13]}"
          "[pf][packet][length]"   => "%{[pfelk_csv][14]}"
          "[source][ip]"           => "%{[pfelk_csv][15]}"
          "[destination][ip]"      => "%{[pfelk_csv][16]}"
        }
      }
      if [network][protocol] == "tcp" {
        mutate {
          add_field => {
            "[source][port]"              => "%{[pfelk_csv][17]}"
            "[destination][port]"         => "%{[pfelk_csv][18]}"
            "[pf][data_length]"           => "%{[pfelk_csv][19]}"
            "[pf][tcp][flags]"            => "%{[pfelk_csv][20]}"
            "[pf][tcp][sequence_number]"  => "%{[pfelk_csv][21]}"
            "[pf][tcp][ack]"              => "%{[pfelk_csv][22]}"
            "[pf][tcp][window]"           => "%{[pfelk_csv][23]}"
            "[pf][tcp][urg]"              => "%{[pfelk_csv][24]}"
            "[pf][tcp][options]"          => "%{[pfelk_csv][25]}"
          }
        }
      }
      if [network][protocol] == "udp" {
        mutate {
          add_field => {
            "[source][port]"      => "%{[pfelk_csv][17]}"
            "[destination][port]" => "%{[pfelk_csv][18]}"
            "[pf][data_length]"   => "%{[pfelk_csv][19]}"
          }
        }
      }
    }
    if [network][direction] =~ /^out$/ {
      mutate {
        rename => { "[pf][data_length]"    => "[destination][bytes]"   }
        rename => { "[pf][packet][length]" => "[destination][packets]" }
      }
    }
    if [network][direction] =~ /^in$/ {
      mutate {
        rename => { "[pf][data_length]"    => "[source][bytes]"   }
        rename => { "[pf][packet][length]" => "[source][packets]" }
      }
    }
    if [network][type] == "4" { mutate { update => { "[network][type]" => "ipv4" } } }
    if [network][type] == "6" { mutate { update => { "[network][type]" => "ipv6" } } }
    if [network][direction] =~ /^in$/  { mutate { update => { "[network][direction]" => "ingress" } } }
    if [network][type]      =~ /^out$/ { mutate { update => { "[network][type]"      => "egress"  } } }
  }
}
EOF
}

# ── Pipeline: 05-apps ──────────────────────────────────────
write_pipeline_05() {
  cat > /etc/pfelk/conf.d/05-apps.pfelk << 'EOF'
filter {
  if [log][syslog][appname] =~ /^logportalauth/ {
    mutate { replace => { "[log][syslog][appname]" => "captiveportal" } }
  }
  if [log][syslog][appname] =~ /^captiveportal/ {
    mutate {
      add_tag => "captive"
      add_field => { "[event][dataset]" => "pfelk.captive" }
      rename => { "filter_message" => "captiveportalmessage" }
    }
    grok { patterns_dir => ["/etc/pfelk/patterns"] match => ["captiveportalmessage", "%{CAPTIVEPORTAL}"] }
  }
  if [log][syslog][appname] =~ /^dhcpd$/ {
    mutate {
      add_tag => ["dhcp","dhcpdv4"]
      add_field => { "[event][dataset]" => "pfelk.dhcp" }
      replace => { "[log][syslog][appname]" => "dhcp" }
    }
    grok { patterns_dir => ["/etc/pfelk/patterns"] match => ["filter_message", "%{DHCPD}"] }
  }
  if [log][syslog][appname] =~ /^dpinger/ {
    mutate { add_tag => "dpinger" add_field => { "[event][dataset]" => "pfelk.dpinger" } }
  }
  if [log][syslog][appname] =~ /^haproxy/ {
    mutate { add_tag => "haproxy" add_field => { "[event][dataset]" => "pfelk.haproxy" } }
    grok { patterns_dir => ["/etc/pfelk/patterns"] match => ["filter_message", "%{HAPROXY}"] }
  }
  if [log][syslog][appname] =~ /^kea-dhcp4$/ {
    mutate {
      add_tag => ["kea-dhcp","dhcp4"]
      add_field => { "[event][dataset]" => "pfelk.kea-dhcp4" }
      replace => { "[log][syslog][appname]" => "kea-dhcp" }
    }
    grok { patterns_dir => ["/etc/pfelk/patterns"] match => ["filter_message", "%{KEADHCP4}"] }
  }
  if [log][syslog][appname] =~ /^kea-dhcp6$/ {
    mutate {
      add_tag => ["kea-dhcp","dhcp6"]
      add_field => { "[event][dataset]" => "pfelk.kea-dhcp6" }
      replace => { "[log][syslog][appname]" => "kea-dhcp" }
    }
  }
  if [log][syslog][appname] =~ /^nginx/ {
    mutate {
      add_tag => "nginx"
      add_field => { "[event][dataset]" => "pfelk.nginx" }
      replace => { "[log][syslog][appname]" => "nginx" }
    }
    grok { patterns_dir => ["/etc/pfelk/patterns"] match => { "filter_message" => "%{NGINX}" } }
  }
  if [log][syslog][appname] =~ /^openvpn/ {
    mutate { add_tag => "openvpn" add_field => { "[event][dataset]" => "pfelk.openvpn" } }
  }
  if [log][syslog][appname] =~ /^named/ {
    mutate { add_tag => "bind9" add_field => { "[event][dataset]" => "pfelk.bind9" } }
    grok { match => ["filter_message", "%{BIND9}"] }
  }
  if [log][syslog][appname] =~ /^ntpd/ {
    mutate { add_tag => "ntpd" add_field => { "[event][dataset]" => "pfelk.ntpd" } }
  }
  if [log][syslog][appname] =~ /^php-fpm/ {
    mutate { add_tag => "web_portal" add_field => { "[event][dataset]" => "pfelk.webportal" } }
    grok { patterns_dir => ["/etc/pfelk/patterns"] match => { "filter_message" => "%{PF_APP} %{PF_APP_DATA}" } }
    mutate { lowercase => ["[pf][app][action]"] }
  }
  if [log][syslog][appname] =~ /^snort/ {
    mutate {
      add_tag => "snort"
      add_field => { "[event][dataset]" => "pfelk.snort" }
      add_field => { "[event][category]" => "intrusion_detection" }
      add_field => { "[agent][type]" => "snort" }
    }
    grok { patterns_dir => ["/etc/pfelk/patterns"] match => ["filter_message", "%{SNORT}"] }
  }
  if [log][syslog][appname] =~ /^suricata$/ {
    if [filter_message] =~ /^\{.*\}$/ {
      json { source => "filter_message" target => "[suricata][eve]" add_tag => "suricata_json" }
    }
    if [suricata][eve][src_ip]   and ![source][ip]        { mutate { add_field => { "[source][ip]"        => "%{[suricata][eve][src_ip]}"   } } }
    if [suricata][eve][dest_ip]  and ![destination][ip]   { mutate { add_field => { "[destination][ip]"   => "%{[suricata][eve][dest_ip]}"  } } }
    if [suricata][eve][src_port] and ![source][port]      { mutate { add_field => { "[source][port]"      => "%{[suricata][eve][src_port]}" } } }
    if [suricata][eve][dest_port] and ![destination][port] {
      mutate {
        add_field => { "[destination][port]" => "%{[suricata][eve][dest_port]}" }
        add_field => { "[threatintel][indicator][ip]" => "%{[source][ip]} %{[suricata][eve][http][url]}" }
      }
    }
    if "suricata_json" not in [tags] {
      grok { patterns_dir => ["/etc/pfelk/patterns"] match => ["filter_message", "%{SURICATA}"] }
    }
    mutate {
      remove_tag => "suricata_json"
      add_tag => "suricata"
      add_field => { "[event][dataset]" => "pfelk.suricata" }
    }
  }
  if [log][syslog][appname] == "(squid-1)" {
    mutate { replace => ["[log][syslog][appname]", "squid"] add_field => { "[event][dataset]" => "pfelk.squid" } }
    if [filter_message] =~ /^\{.*\}$/ {
      json { source => "filter_message" add_tag => "squid_json" }
    }
    if "squid_json" not in [tags] {
      grok { patterns_dir => ["/etc/pfelk/patterns"] match => ["filter_message", "%{SQUID}"] }
    }
    mutate { remove_tag => "squid_json" add_tag => "squid" }
  }
  if [log][syslog][appname] =~ /^unbound/ {
    mutate { add_tag => "unbound" add_field => { "[event][dataset]" => "pfelk.unbound" } }
    grok { patterns_dir => ["/etc/pfelk/patterns"] match => ["filter_message", "%{UNBOUND}"] }
    grok {
      match => ["[dns][question][name]", "(\.)?(?<[dns][question][registered_domain]>[^.]+\.[^.]+)$"]
      add_tag => "unbound-registered_domain"
    }
    if "unbound-registered_domain" not in [tags] {
      grok { match => ["[dns][question][name]", "(?<[dns][question][registered_domain]>[^.]+\.[^.]+)$"] }
    }
    grok { match => ["[dns][question][name]", "(\.)?(?<[dns][question][top_level_domain]>[^.]+)$"] }
    mutate { remove_tag => "unbound-registered_domain" }
  }
}
EOF
}

# ── Pipeline: 30-geoip ─────────────────────────────────────
write_pipeline_30() {
  cat > /etc/pfelk/conf.d/30-geoip.pfelk << 'EOF'
filter {
  if "pfelk" in [tags] {
    if [source][ip] {
      cidr {
        address => ["%{[source][ip]}"]
        network => ["0.0.0.0/32","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","255.255.255.255/32","fe80::/10","fc00::/7","ff00::/8","::1/128","::"]
        add_tag => "IP_Private_Source"
      }
      if "IP_Private_Source" not in [tags] {
        geoip { source => "[source][ip]" }
        geoip { source => "[source][ip]" default_database_type => "ASN" }
        mutate { add_tag => "GeoIP_Source" }
      }
    }
    if [destination][ip] {
      cidr {
        address => ["%{[destination][ip]}"]
        network => ["0.0.0.0/32","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","255.255.255.255/32","fe80::/10","fc00::/7","ff00::/8","::1/128","::"]
        add_tag => "IP_Private_Destination"
      }
      if "IP_Private_Destination" not in [tags] {
        geoip { source => "[destination][ip]" }
        geoip { source => "[destination][ip]" default_database_type => "ASN" }
        mutate { add_tag => "GeoIP_Destination" }
      }
    }
  }
  if "haproxy" in [tags] or "nginx" in [tags] {
    if [client][ip] {
      cidr {
        address => ["%{[client][ip]}"]
        network => ["0.0.0.0/32","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","255.255.255.255/32","fe80::/10","fc00::/7","ff00::/8","::1/128","::"]
        add_tag => "IP_Private_Proxy"
      }
      if "IP_Private_Proxy" not in [tags] {
        geoip { source => "[client][ip]" }
        geoip { source => "[client][ip]" default_database_type => "ASN" }
        mutate { add_tag => "GeoIP_Source" }
      }
    }
  }
}
EOF
}

# ── Pipeline: 49-cleanup ───────────────────────────────────
write_pipeline_49() {
  cat > /etc/pfelk/conf.d/49-cleanup.pfelk << 'EOF'
filter {
  mutate {
    remove_field => ["filter_message","pfelk","pfelk_csv"]
    split => { "[pf][tcp][options]"         => ";" }
    split => { "[openvpn][client][sso]"     => "," }
    split => { "[openvpn][client][ciphers]" => ":" }
    rename => { "message" => "[event][original]" }
  }
  ruby {
    code => '
      if event.get("[pf][tcp][sequence_number]")
        seq = event.get("[pf][tcp][sequence_number]")
        if seq.include?(":")
          s, e = seq.split(":")
          event.set("[pf][tcp][sequence_number]", s.to_i)
          event.set("[pf][tcp][sequence_number_range_end]", e.to_i)
        else
          event.set("[pf][tcp][sequence_number]", seq.to_i)
        end
      end
    '
  }
}
EOF
}

# ── Pipeline: 50-outputs ───────────────────────────────────
write_pipeline_50() {
  cat > /etc/pfelk/conf.d/50-outputs.pfelk << 'EOF'
filter {
  if      [log][syslog][appname] == "captiveportal"                                                    { mutate { add_field => { "[data_stream][namespace]" => "captiveportal"    } } }
  else if [log][syslog][appname] == "dhcp"                                                             { mutate { add_field => { "[data_stream][namespace]" => "dhcp"             } } }
  else if [log][syslog][appname] == "firewall"                                                         { mutate { add_field => { "[data_stream][namespace]" => "firewall"         } } }
  else if "bind9" in [tags] or "dpinger" in [tags] or "ntpd" in [tags] or "web_portal" in [tags]     { mutate { add_field => { "[data_stream][namespace]" => "firewall_processes"} } }
  else if [log][syslog][appname] == "haproxy"                                                          { mutate { add_field => { "[data_stream][namespace]" => "haproxy"          } } }
  else if [log][syslog][appname] == "kea-dhcp"                                                         { mutate { add_field => { "[data_stream][namespace]" => "kea-dhcp"         } } }
  else if [log][syslog][appname] == "nginx"                                                            { mutate { add_field => { "[data_stream][namespace]" => "nginx"            } } }
  else if [log][syslog][appname] == "openvpn"                                                          { mutate { add_field => { "[data_stream][namespace]" => "openvpn"          } } }
  else if [log][syslog][appname] == "unbound"                                                          { mutate { add_field => { "[data_stream][namespace]" => "unbound"          } } }
  else if [log][syslog][appname] == "suricata"                                                         { mutate { add_field => { "[data_stream][namespace]" => "suricata"         } } }
  else if [log][syslog][appname] == "snort"                                                            { mutate { add_field => { "[data_stream][namespace]" => "snort"            } } }
  else if [log][syslog][appname] == "squid"                                                            { mutate { add_field => { "[data_stream][namespace]" => "squid"            } } }
  else                                                                                                  { mutate { add_field => { "[data_stream][namespace]" => "unknown"          } } }
}
output {
  elasticsearch {
    data_stream         => "true"
    data_stream_type    => "logs"
    data_stream_dataset => "pfelk"
    hosts    => ["https://localhost:9200"]
    user     => "elastic"
    password => "${ELASTIC_PASSWORD}"
    ssl_enabled => true
    ssl_certificate_authorities => ["/etc/pfelk/config/certs/http_ca.crt"]
  }
}
EOF
}

# ── Fire all config writes in parallel ─────────────────────
write_es_config    &
write_ls_config    &
write_kb_config    &
write_grok_patterns &
write_pipeline_01  &
write_pipeline_02  &
write_pipeline_05  &
write_pipeline_30  &
write_pipeline_49  &
write_pipeline_50  &
wait
systemctl daemon-reload
msg_ok "Configured ELK Stack"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — Start Elasticsearch and wait
# ══════════════════════════════════════════════════════════════════════════════
msg_info "Starting Elasticsearch"
systemctl enable -q --now elasticsearch

# Poll at 3-second intervals — faster than the usual 5 s
for i in $(seq 1 80); do
  HTTP=$(curl -sk -o /dev/null -w "%{http_code}" https://localhost:9200/ 2>/dev/null || echo 0)
  [[ "$HTTP" =~ ^(200|401)$ ]] && break
  sleep 3
done
msg_ok "Elasticsearch is ready"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — TLS cert + passwords
# ══════════════════════════════════════════════════════════════════════════════
msg_info "Configuring Security"

# Copy auto-generated CA cert to pfelk and Kibana config locations
ES_CA="/etc/elasticsearch/certs/http_ca.crt"
cp "$ES_CA" /etc/pfelk/config/certs/http_ca.crt
chown -R logstash:logstash /etc/pfelk

# Reset elastic user password to our generated value
/usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u elastic --batch --url https://localhost:9200 \
  -i <<< "${ELASTIC_PASSWORD}"$'\n'"${ELASTIC_PASSWORD}" &>/dev/null || true

# Confirm auth works before setting dependent passwords
for i in $(seq 1 20); do
  HTTP=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u "elastic:${ELASTIC_PASSWORD}" https://localhost:9200/ 2>/dev/null || echo 0)
  [[ "$HTTP" == "200" ]] && break
  sleep 3
done

# Set kibana_system and logstash_system passwords (in parallel — independent calls)
curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST https://localhost:9200/_security/user/kibana_system/_password \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${KIBANA_PASSWORD}\"}" &>/dev/null &

curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST https://localhost:9200/_security/user/logstash_system/_password \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${LOGSTASH_PASSWORD}\"}" &>/dev/null &

wait
msg_ok "Security Configured"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — Start Logstash and Kibana in parallel
# ══════════════════════════════════════════════════════════════════════════════
msg_info "Starting Logstash and Kibana"
systemctl enable -q logstash kibana
systemctl start logstash &
systemctl start kibana   &
wait
msg_ok "Logstash and Kibana started"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 8 — Import pfelk dashboards
#           Kibana startup takes ~60 s; we poll cheaply while it initialises
# ══════════════════════════════════════════════════════════════════════════════
msg_info "Waiting for Kibana to become available"
for i in $(seq 1 80); do
  STATUS=$(curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
    http://localhost:5601/api/status 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status']['overall']['level'])" 2>/dev/null || echo "")
  [[ "$STATUS" == "available" ]] && break
  sleep 3
done
msg_ok "Kibana is available"

msg_info "Importing pfelk Dashboards"
mkdir -p /tmp/pfelk-dashboards

# Fetch the dashboard list from pfelk GitHub, filter to latest per-topic NDJSON
mapfile -t DASH_URLS < <(
  curl -fsSL "https://api.github.com/repos/pfelk/pfelk/contents/etc/pfelk/dashboard" \
  | python3 -c "
import sys, json, re
items = json.load(sys.stdin)
# Keep only .ndjson files; pick the newest version per topic (sort by name desc)
ndj = sorted(
  [x for x in items if x['name'].endswith('.ndjson')],
  key=lambda x: x['name'], reverse=True
)
seen = set()
for item in ndj:
    # Topic = everything after the version prefix (e.g. 'firewall', 'suricata')
    m = re.match(r'^[\d.]+-(.+)\.ndjson$', item['name'])
    topic = m.group(1) if m else item['name']
    if topic not in seen:
        seen.add(topic)
        print(item['download_url'])
" 2>/dev/null || true
)

# Download and import each dashboard in parallel (max 4 concurrent)
import_dashboard() {
  local url="$1"
  local name; name=$(basename "$url")
  local dest="/tmp/pfelk-dashboards/${name}"
  curl -fsSL "$url" -o "$dest" 2>/dev/null || return 0
  curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
    -X POST "http://localhost:5601/api/saved_objects/_import?overwrite=true" \
    -H "kbn-xsrf: true" \
    --form "file=@${dest}" &>/dev/null || true
}

# Batch-parallel import with a semaphore (4 slots) to avoid overwhelming Kibana
MAX_PARALLEL=4
running=0
for url in "${DASH_URLS[@]}"; do
  import_dashboard "$url" &
  (( ++running ))
  if (( running >= MAX_PARALLEL )); then
    wait -n 2>/dev/null || wait   # wait for any one job (-n is bash 4.3+)
    (( --running ))
  fi
done
wait

rm -rf /tmp/pfelk-dashboards
msg_ok "Imported pfelk Dashboards"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 9 — Persist credentials
# ══════════════════════════════════════════════════════════════════════════════
LXC_IP=$(hostname -I | awk '{print $1}')
{
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " pfelk Credentials"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Kibana URL:       http://${LXC_IP}:5601"
  echo " Username:         elastic"
  echo " Password:         ${ELASTIC_PASSWORD}"
  echo ""
  echo " OPNsense syslog:  ${LXC_IP}:5140 (UDP/TCP)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
} > ~/pfelk.creds
chmod 600 ~/pfelk.creds

motd_ssh
customize
cleanup_lxc
