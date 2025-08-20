#!/bin/sh

printf 'Введите vless:// ссылку (ОБЯЗАТЕЛЬНО REALITY): '
IFS= read -r input

wrapped="'$input'"

printf "\033[32;1mInstalling packages\033[0m\n"
opkg update && opkg install curl kmod-nft-tproxy sing-box jq dnsproxy

curl -Lo /tmp/gen.sh https://raw.githubusercontent.com/ivszr/fast-sing-box/refs/heads/main/gen.sh

printf "\033[32;1mEnabling sing-box service\033[0m\n"
if grep -q "option enabled '0'" /etc/config/sing-box; then
    sed -i "s/	option enabled '0'/	option enabled '1'/" /etc/config/sing-box
fi
if grep -q "option user 'sing-box'" /etc/config/sing-box; then
    sed -i "s/	option user 'sing-box'/	option user 'root'/" /etc/config/sing-box
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

uci add firewall rule
uci set firewall.@rule[-1]=rule
uci set firewall.@rule[-1].name='Traffic to proxy'
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

service dnsmasq stop
uci set dhcp.@dnsmasq[0].noresolv="1"
uci set dhcp.@dnsmasq[0].cachesize="10000"
uci set dhcp.@dnsmasq[0].min_cache_ttl="3600"
uci set dhcp.@dnsmasq[0].max_cache_ttl="86400"
uci -q del dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#5354"
uci add_list dhcp.@dnsmasq[0].server="::1#5354"
uci commit dhcp
service dnsmasq start
 
# Configure dnsproxy
uci set dnsproxy.global.enabled="1"
uci del dnsproxy.global.listen_port
uci add_list dnsproxy.global.listen_port="5354"
uci set dnsproxy.cache.enabled="0"  # "1" to enable (Enable this ONLY if you want to test "cache_optimistic" option)
uci set dnsproxy.cache.cache_optimistic="1"
uci set dnsproxy.cache.size="2097152"  # Equal to 2 MB (in binary)
uci del dnsproxy.servers.bootstrap
uci add_list dnsproxy.servers.bootstrap="8.8.8.8"
uci add_list dnsproxy.servers.bootstrap="tcp://8.8.8.8"
uci del dnsproxy.servers.upstream
uci add_list dnsproxy.servers.upstream="https://8.8.8.8/dns-query"
uci commit dnsproxy

cat << "EOF" > /etc/sysctl.d/12-buffer-size.conf
net.core.rmem_max=7500000
net.core.wmem_max=7500000
EOF
sysctl -p /etc/sysctl.d/12-buffer-size.conf

uci del system.ntp.server
uci add_list system.ntp.server="216.239.35.0"     # time.google.com
uci add_list system.ntp.server="216.239.35.4"     # time.google.com
uci add_list system.ntp.server="216.239.35.8"     # time.google.com
uci add_list system.ntp.server="216.239.35.12"    # time.google.com
uci add_list system.ntp.server="162.159.200.123"  # time.cloudflare.com
uci add_list system.ntp.server="162.159.200.1"    # time.cloudflare.com
uci commit system

# Intercept DNS traffic
uci -q del firewall.dns_int
uci set firewall.dns_int="redirect"
uci set firewall.dns_int.name="Intercept-DNS"
uci set firewall.dns_int.family="any"
uci set firewall.dns_int.proto="tcp udp"
uci set firewall.dns_int.src="lan"
uci set firewall.dns_int.src_dport="53"
uci set firewall.dns_int.target="DNAT"
uci commit firewall

sh /tmp/gen.sh "$wrapped" > /etc/sing-box/config.json

printf "\033[32;1mInstallation done!\033[0m\n"
service system restart && service dnsmasq restart && service network restart && service firewall restart && service dnsproxy restart && service sing-box restart
