#!/usr/bin/env sh

NEED_UPDATE=1
DEPENDENCIES="sing-box-tiny kmod-nft-tproxy"

get_timestamp() {
  format="$1"
  date +"$format"
}

log_message() {
  log_level="$1"
  message="$2"
  timestamp=$(get_timestamp "%d.%m.%Y %H:%M:%S")
  echo "[$timestamp] [$log_level]: $message"
}

is_installed() {
  opkg list-installed | grep -qo "$1"
}

check_updates() {
  if [ "$NEED_UPDATE" -eq "1" ]; then
    log_message "INFO" "Updating package list"
    opkg update >/dev/null
    NEED_UPDATE=0
  fi
}

install_dependencies() {
  for package in $DEPENDENCIES; do
    if ! is_installed "$package"; then
      check_updates
      log_message "INFO" "Installing $package"
      opkg install "$package" >/dev/null
    fi
  done
}

configure_sing_box_service() {
  sing_box_enabled=$(uci -q get sing-box.main.enabled)
  sing_box_user=$(uci -q get sing-box.main.user)

  if [ "$sing_box_enabled" != "1" ]; then
    log_message "INFO" "Enabling sing-box service"
    uci -q set sing-box.main.enabled=1
    uci commit sing-box
  fi

  if [ "$sing_box_user" != "root" ]; then
    log_message "INFO" "Setting sing-box user to root"
    uci -q set sing-box.main.user=root
    uci commit sing-box
  fi
}

configure_dhcp() {
  is_noresolv_enabled=$(uci -q get dhcp.@dnsmasq[0].noresolv || echo "0")
  is_filter_aaaa_enabled=$(uci -q get dhcp.@dnsmasq[0].filter_aaaa || echo "0")
  is_locause_disabled=$(uci -q get dhcp.@dnsmasq[0].localuse || echo "1")
  dhcp_server_ip="127.0.0.1#5353"

  if [ "$is_noresolv_enabled" -ne "1" ]; then
    log_message "INFO" "Enabling noresolv option in DHCP config"
    uci -q set dhcp.@dnsmasq[0].noresolv=1
    uci commit dhcp
  fi

  if [ "$is_filter_aaaa_enabled" -ne "1" ]; then
    log_message "INFO" "Enabling filter_aaaa option in DHCP config"
    uci -q set dhcp.@dnsmasq[0].filter_aaaa=1
    uci commit dhcp
  fi

  if [ "$is_locause_disabled" -ne "0" ]; then
    log_message "INFO" "Disabling localuse option in DHCP config"
    uci -q set dhcp.@dnsmasq[0].localuse=0
    uci commit dhcp
  fi

  log_message "INFO" "Pointing dnsmasq to $dhcp_server_ip"
  uci -q delete dhcp.@dnsmasq[0].server
  uci -q add_list dhcp.@dnsmasq[0].server="$dhcp_server_ip"
  uci commit dhcp
}

configure_network() {
  if [ -z "$(uci -q get network.@rule[0])" ]; then
    log_message "INFO" "Creating marking rule"
    uci batch <<EOI
add network rule
set network.@rule[0].name='mark0x1'
set network.@rule[0].mark='0x1'
set network.@rule[0].priority='100'
set network.@rule[0].lookup='100'
EOI
    uci commit network
  fi
}

configure_nftables() {
  log_message "INFO" "Configuring nftables & hotplug"
  mkdir -p /etc/nftables.d
  mkdir -p /etc/hotplug.d/iface

  cat > /etc/hotplug.d/iface/30-tproxy <<'EOF'
#!/bin/sh
ip route add local default dev lo table 100
EOF
  chmod +x /etc/hotplug.d/iface/30-tproxy

  cat > /etc/nftables.d/30-sing-box-tproxy.nft <<'EOF'
chain tproxy_marked {
  type filter hook prerouting priority filter; policy accept;
  meta mark 0x1 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:12701 counter accept
}
EOF
}

configure_firewall() {
  log_message "INFO" "Configuring firewall rules"
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='To proxy'
  uci set firewall.@rule[-1].src='lan'
  uci set firewall.@rule[-1].dest='*'
  uci set firewall.@rule[-1].src_ip='192.168.0.0/16'
  uci set firewall.@rule[-1].dest_ip='!192.168.0.0/16'
  uci add_list firewall.@rule[-1].proto='all'
  uci set firewall.@rule[-1].target='MARK'
  uci set firewall.@rule[-1].set_mark='0x1'
  uci set firewall.@rule[-1].family='ipv4'
  uci commit firewall
}

configure_sing_box() {
  log_message "INFO" "Requesting vless:// reality link from user"
  printf "Enter your vless:// reality link:\n"
  read -r URL

  # --- парсер VLESS ссылки ---
  URL=${URL//$'\r'/}
  URL=${URL//$'\n'/}

  urldecode() {
      printf '%b' "${1//%/\\x}" | sed 's/+/ /g'
  }

  URL_NOPREFIX=${URL#vless://}
  NOHASH=${URL_NOPREFIX%%#*}

  UUID=${NOHASH%%@*}
  HOSTPORT=${NOHASH#*@}

  HOST=${HOSTPORT%%[:/?]*}
  PORT=${HOSTPORT#*:}
  [ "$PORT" = "$HOSTPORT" ] && PORT=443 || PORT=${PORT%%[/?]*}

  QUERY=${HOSTPORT#*\?}
  [ "$QUERY" != "$HOSTPORT" ] || QUERY=""

  get_param() {
      for kv in ${QUERY//&/ }; do
          case $kv in
              $1=*) echo "${kv#*=}" ;;
          esac
      done
  }

  FLOW=$(get_param flow)
  SNI=$(get_param sni)
  FP=$(get_param fp)
  PBK=$(get_param pbk)
  SID=$(get_param sid)

  log_message "INFO" "Generating /etc/sing-box/config.json"
  cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "debug"
  },
  "dns": {
    "strategy": "ipv4_only",
    "final": "proxy-dns",
    "independent_cache": true,
    "servers": [
      {
        "tag": "bootstrap-dns",
        "address": "https://8.8.8.8/dns-query",
        "detour": "direct-out"
      },
      {
        "tag": "proxy-dns",
        "address": "https://8.8.8.8/dns-query",
        "detour": "proxy"
      }
    ],
    "rules": [
      {
        "domain": ["$HOST"],
        "server": "bootstrap-dns"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tproxy",
      "listen": "::",
      "listen_port": 12701,
      "sniff": false
    },
    {
      "tag": "dns-in",
      "type": "direct",
      "listen": "127.0.0.1",
      "listen_port": 5353
    }
  ],
  "outbounds": [
    {
      "tag": "direct-out",
      "type": "direct"
    },
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$HOST",
      "server_port": $PORT,
      "uuid": "$UUID",
      "flow": "$FLOW",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "$FP"
        },
        "reality": {
          "enabled": true,
          "public_key": "$PBK",
          "short_id": "$SID"
        }
      }
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          "dns-in",
          "tproxy-in"
        ],
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      }
    ],
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

restart_service() {
  service="$1"
  log_message "INFO" "Restarting $service service"
  /etc/init.d/$service restart
}

print_post_install_message() {
  printf "\nInstallation completed successfully ✅\n"
}

main() {
  install_dependencies
  configure_sing_box_service
  configure_dhcp
  configure_network
  configure_nftables
  configure_firewall
  configure_sing_box
  restart_service "network"
  restart_service "dnsmasq"
  restart_service "firewall"
  restart_service "sing-box"
  print_post_install_message
}

main
