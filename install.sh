#!/bin/sh

printf "\033[32;1mInstalling packeges\033[0m\n"
opkg update && opkg install curl kmod-nft-tproxy sing-box nano

printf "\033[32;1mDownloading config.json\033[0m\n"
curl -Lo /etc/sing-box/config.json https://raw.githubusercontent.com/ivszr/fast-sing-box/refs/heads/main/config.json

printf "\033[32;1mEnabling sing-box service\033[0m\n"
if grep -q "option enabled '0'" /etc/config/sing-box; then
    sed -i "s/	option enabled \'0\'/	option enabled \'1\'/" /etc/config/sing-box
fi
if grep -q "option user 'sing-box'" /etc/config/sing-box; then
    sed -i "s/	option user \'sing-box\'/	option user \'root\'/" /etc/config/sing-box
fi
service sing-box enable

printf "\033[32;1mConfigure network\033[0m\n"
rule_id=$(uci show network | grep -E '@rule.*name=.mark0x1.' | awk -F '[][{}]' '{print $2}' | head -n 1)
if [ ! -z "$rule_id" ]; then
    while uci -q delete network.@rule[$rule_id]; do :; done
fi

uci add network rule
uci set network.@rule[-1].name='mark0x1'
uci set network.@rule[-1].mark='0x1'
uci set network.@rule[-1].priority='100'
uci set network.@rule[-1].lookup='100'
uci commit network

echo "#!/bin/sh" > /etc/hotplug.d/iface/30-tproxy
echo "ip route add local default dev lo table 100" >> /etc/hotplug.d/iface/30-tproxy

printf "\033[32;1mConfigure firewall\033[0m\n"
rule_id2=$(uci show firewall | grep -E '@rule.*name=.Fake IP via proxy.' | awk -F '[][{}]' '{print $2}' | head -n 1)
if [ ! -z "$rule_id2" ]; then
    while uci -q delete firewall.@rule[$rule_id2]; do :; done
fi
printf "\033[32;1mConfigure dhcp\033[0m\n"
configure_dhcp() {
  is_noresolv_enabled=$(uci -q get dhcp.@dnsmasq[0].noresolv || echo "0")
  is_filter_aaaa_enabled=$(uci -q get dhcp.@dnsmasq[0].filter_aaaa || echo "0")
  dhcp_server=$(uci -q get dhcp.@dnsmasq[0].server || echo "")
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

  if [ "$dhcp_server" != "$dhcp_server_ip" ]; then
    log_message "INFO" "Setting DHCP server to $dhcp_server_ip"
    uci -q delete dhcp.@dnsmasq[0].server
    uci -q add_list dhcp.@dnsmasq[0].server="$dhcp_server_ip"
    uci commit dhcp
  fi
}

uci add firewall rule
uci set firewall.@rule[-1]=rule
uci set firewall.@rule[-1].name='Fake IP via proxy'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='*'
uci set firewall.@rule[-1].src_ip='192.168.0.0/16'
uci set firewall.@rule[-1].dest_ip='!192.168.0.0/16'
uci add_list firewall.@rule[-1].proto='tcp'
uci add_list firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='MARK'
uci set firewall.@rule[-1].set_mark='0x1'
uci set firewall.@rule[-1].family='ipv4'
uci commit firewall

echo "chain tproxy_marked {" > /etc/nftables.d/30-sing-box-tproxy.nft
echo "  type filter hook prerouting priority filter; policy accept;" >> /etc/nftables.d/30-sing-box-tproxy.nft
echo "  meta mark 0x1 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:12701 counter accept" >> /etc/nftables.d/30-sing-box-tproxy.nft
echo "}" >> /etc/nftables.d/30-sing-box-tproxy.nft

printf "\033[32;1mPlease adjust config and run service sing-box restart, Internet access unavailable wihout correct config\033[0m\n"
service dnsmasq restart && service network restart && service firewall restart


