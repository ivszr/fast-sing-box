#!/bin/sh

URL=${1//$'\r'/}
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

jq -n \
  --arg server "$HOST" \
  --arg port   "$PORT" \
  --arg uuid   "$UUID" \
  --arg flow   "$FLOW" \
  --arg sni    "$SNI" \
  --arg fp     "$FP" \
  --arg pbk    "$PBK" \
  --arg sid    "$SID" \
'{
  log: { level: "debug" },
  dns: {
    servers: [
      {
        type: "https",
        tag: "google-doh",

        server: "8.8.8.8",
        server_port: 443,
      }
    ]
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
      type: "direct",
      listen: "127.0.0.1",
      listen_port: 5353
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
    },
    {
      type: "direct",
      tag: "direct"
    }
  ],
  route: {
    auto_detect_interface: true,
    final: "proxy"
  }
}'
