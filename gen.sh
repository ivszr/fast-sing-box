#!/bin/ash

URL=${1//$'\r'/}
URL=${URL//$'\n'/}

urldecode() {
  printf '%b' "${1//%/\x}" | sed 's/+/ /g'
}

URL_NOPREFIX=${URL#vless://}
NOHASH=${URL_NOPREFIX%%#*}

UUID=${NOHASH%%@}
HOSTPORT=${NOHASH#@}

HOST=${HOSTPORT%%[:/?]}
PORT=${HOSTPORT#:}
[ "$PORT" = "$HOSTPORT" ] && PORT=443 || PORT=${PORT%%[/?]*}

QUERY=${HOSTPORT#*?}
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

jq -n \
--arg server "$HOST" \
--arg port "$PORT" \
--arg uuid "$UUID" \
--arg flow "$FLOW" \
--arg sni "$SNI" \
--arg fp "$FP" \
--arg pbk "$PBK" \
--arg sid "$SID" \
'{
  log: { level: "debug" },

  dns: {
    servers: [
      {
        tag: "doh",
        address: "https://1.1.1.1/dns-query",
        address_resolver: "local",
        strategy: "ipv4_only"
      }
    ],
    disable_cache: false,
    disable_expire: false
  },

  inbounds: [
    {
      tag: "tproxy-in",
      type: "tproxy",
      listen: "::",
      listen_port: 12701,
      tcp_fast_open: true,
      udp_fragment: true
    },
    {
      tag: "dns-in",
      type: "dns",
      listen: "127.0.0.1",
      listen_port: 1053
    }
  ],

  outbounds: [
    {
      type: "vless",
      tag: "proxy",
      server: $server,
      server_port: ($port|tonumber),
      uuid: $uuid,
      flow: $flow,
      packet_encoding: "xudp",
      domain_strategy: "ipv4_only",
      tls: {
        enabled: true,
        insecure: false,
        server_name: $sni,
        utls: { enabled: true, fingerprint: $fp },
        reality: { enabled: true, public_key: $pbk, short_id: $sid }
      }
    }
  ],

  route: {
    auto_detect_interface: true,
    rules: [
      { protocol: "dns", outbound: "dns-out" }
    ],
    final: "proxy"
  }
}'
