#!/bin/sh

printf 'Введите vless:// ссылку (ОБЯЗАТЕЛЬНО REALITY): '
IFS= read -r input

wrapped="'$input'"

printf "\033[32;1mInstalling packages\033[0m\n"
opkg update && opkg install curl kmod-nft-tproxy sing-box jq 

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

sh /tmp/gen.sh "$wrapped" > /etc/sing-box/config.json

printf "\033[32;1mInstallation done!\033[0m\n"
service dnsmasq restart && service network restart && service firewall restart && service sing-box restart
