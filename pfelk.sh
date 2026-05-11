#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Author: pfelk community
# License: MIT
# Source: https://github.com/pfelk/pfelk

APP="pfelk"
var_tags="${var_tags:-security;elk;ids;monitoring}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-32}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /etc/pfelk ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Stopping Logstash and Kibana"
  systemctl stop logstash kibana
  msg_ok "Stopped Services"

  msg_info "Updating ELK Stack"
  $STD apt-get update
  $STD apt-get install -y --only-upgrade elasticsearch logstash kibana
  msg_ok "Updated ELK Stack"

  msg_info "Restarting Services"
  systemctl start logstash kibana
  msg_ok "Restarted Services"

  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access Kibana at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:5601${CL}"
echo -e "${INFO}${YW} OPNsense syslog target:${CL}"
echo -e "${TAB}${BGN}${IP}:5140 (UDP/TCP)${CL}"
echo -e "${INFO}${YW} Credentials stored in the container at:${CL}"
echo -e "${TAB}${BGN}~/pfelk.creds${CL}"
