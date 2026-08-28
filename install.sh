#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.2.0"
APP="Pterodactyl DDoS Mitigation by Syncara Cloud"
BIN="/usr/local/sbin/ptero-guard"
CONF="/etc/ptero-guard.conf"
SERVICE="/etc/systemd/system/ptero-guard.service"
TABLE="ptero_detect"
DISCORD_WEBHOOK_SELECTED=""
TCP_PORT_SET=""
UDP_PORT_SET=""

C_RESET="\033[0m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_CYAN="\033[36m"
C_BOLD="\033[1m"

info() { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
fail() { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2; }
die()  { fail "$*"; exit 1; }

ask_yes_no() {
  local prompt="$1" default="${2:-Y}" answer
  if [[ "$default" == "Y" ]]; then
    read -r -p "$prompt [Y/n]: " answer
    answer="${answer:-Y}"
  else
    read -r -p "$prompt [y/N]: " answer
    answer="${answer:-N}"
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

ask_value() {
  local prompt="$1" default="$2" out
  read -r -p "$prompt [$default]: " out
  printf '%s' "${out:-$default}"
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run the installer as root."
}

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release was not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    debian)
      [[ "${VERSION_ID:-}" == "13" ]] || warn "This installer targets Debian 13; Debian ${VERSION_ID:-unknown} was detected."
      ;;
    ubuntu)
      warn "This installer targets Debian 13; Ubuntu ${VERSION_ID:-unknown} was detected."
      ;;
    *)
      die "Unsupported operating system: ${ID:-unknown}"
      ;;
  esac
}

detect_wan() {
  ip -4 route show default | awk 'NR==1 {print $5}'
}

detect_public_ip() {
  local wan="$1"
  ip -4 -o addr show dev "$wan" scope global 2>/dev/null |
    awk 'NR==1 {split($4,a,"/"); print a[1]}'
}

install_deps() {
  info "Installing dependencies..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nftables curl jq ca-certificates iproute2
  ok "Dependencies are ready."
}

backup_firewall() {
  local dir="/root/ptero-guard-backup" ts
  mkdir -p "$dir"
  ts="$(date +%F-%H%M%S)"

  nft list ruleset > "$dir/nft-$ts.conf" 2>/dev/null || true
  iptables-save > "$dir/iptables-$ts.rules" 2>/dev/null || true
  ip6tables-save > "$dir/ip6tables-$ts.rules" 2>/dev/null || true

  ok "Firewall backup saved to $dir"
}

valid_webhook_format() {
  [[ "$1" =~ ^https://(discord(app)?\.com)/api/webhooks/[0-9]+/[A-Za-z0-9._-]+ ]]
}

test_webhook_direct() {
  local webhook="$1" node="$2" ip="$3" code payload

  payload="$(jq -n \
    --arg node "$node" \
    --arg ip "$ip" \
    '{
      username:"Pterodactyl Flood Guard",
      embeds:[{
        title:"✅ Discord Webhook Connected",
        description:"The Ptero Guard installer connected to Discord successfully.",
        color:3066993,
        fields:[
          {name:"Node",value:("`"+$node+"`"),inline:true},
          {name:"Public IP",value:("`"+$ip+"`"),inline:true},
          {name:"Status",value:"Installer Test",inline:true}
        ],
        footer:{text:"Ptero Guard Installer"}
      }]
    }')"

  code="$(curl --silent --show-error \
    --output /tmp/ptero-guard-webhook-test.out \
    --write-out '%{http_code}' \
    --max-time 12 \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "$payload" \
    "$webhook" || true)"

  [[ "$code" == "204" || "$code" == "200" ]]
}

discord_wizard() {
  local node="$1" ip="$2" webhook=""
  DISCORD_WEBHOOK_SELECTED=""

  if ! ask_yes_no "Enable Discord notifications?" "Y"; then
    return 0
  fi

  while true; do
    echo
    echo -e "${C_CYAN}Paste your Discord webhook.${C_RESET}"
    echo "Your input is hidden so the webhook URL is not shown on screen."
    read -r -s -p "Discord Webhook: " webhook
    echo

    if [[ -z "$webhook" ]]; then
      warn "Webhook is empty."
      if ask_yes_no "Try again?" "Y"; then
        continue
      else
        return 0
      fi
    fi

    if ! valid_webhook_format "$webhook"; then
      warn "The Discord webhook format appears invalid."
      if ask_yes_no "Enter it again?" "Y"; then
        continue
      fi
    fi

    info "Testing the Discord webhook..."
    if test_webhook_direct "$webhook" "$node" "$ip"; then
      ok "Webhook succeeded. Check your Discord channel."
      DISCORD_WEBHOOK_SELECTED="$webhook"
      return 0
    fi

    fail "The webhook did not accept the test."
    if ask_yes_no "Try another webhook?" "Y"; then
      continue
    fi

    if ask_yes_no "Continue installation without Discord?" "N"; then
      return 0
    fi

    die "Installation cancelled."
  done
}

choose_profile() {
  echo
  echo -e "${C_BOLD}Choose a protection profile:${C_RESET}"
  echo "  1) Recommended  - suitable for general Minecraft hosting"
  echo "  2) Relaxed      - higher thresholds"
  echo "  3) Strict       - lower thresholds"
  echo "  4) Custom       - configure your own values"
  echo
  read -r -p "Choose [1-4] (default 1): " profile
  profile="${profile:-1}"

  case "$profile" in
    1)
      TCP_SYN_RATE=1500
      TCP_PACKET_RATE=50000
      UDP_PACKET_RATE=20000
      ;;
    2)
      TCP_SYN_RATE=3000
      TCP_PACKET_RATE=100000
      UDP_PACKET_RATE=40000
      ;;
    3)
      TCP_SYN_RATE=750
      TCP_PACKET_RATE=25000
      UDP_PACKET_RATE=10000
      ;;
    4)
      TCP_SYN_RATE="$(ask_value "TCP SYN limit per port /second" "1500")"
      TCP_PACKET_RATE="$(ask_value "TCP packet limit per port /second" "50000")"
      UDP_PACKET_RATE="$(ask_value "UDP packet limit per port /second" "20000")"
      ;;
    *)
      warn "Invalid selection; using Recommended."
      TCP_SYN_RATE=1500
      TCP_PACKET_RATE=50000
      UDP_PACKET_RATE=20000
      ;;
  esac

  TCP_SYN_BURST=$((TCP_SYN_RATE * 2))
  TCP_PACKET_BURST=$((TCP_PACKET_RATE * 2))
  UDP_PACKET_BURST=$((UDP_PACKET_RATE * 2))
}

port_wizard() {
  local ufw_status line target base proto
  local -a ranges=()
  local -a selected=()
  local -A seen=()
  local -A protos=()

  TCP_PORT_SET=""
  UDP_PORT_SET=""

  echo
  echo -e "${C_BOLD}Detecting port ranges from UFW...${C_RESET}"

  if ! command -v ufw >/dev/null 2>&1; then
    warn "UFW was not found."
    manual_port_wizard
    return
  fi

  ufw_status="$(ufw status 2>/dev/null || true)"

  if ! grep -q '^Status: active' <<< "$ufw_status"; then
    warn "UFW is not active."
    manual_port_wizard
    return
  fi

  # Read only IPv4 ALLOW IN rules with a numeric port range target.
  # Example:
  # 20000:60000/tcp   ALLOW IN   Anywhere
  # 20000:60000/udp   ALLOW IN   Anywhere
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    target="$(awk '{print $1}' <<< "$line")"

    # Ignore IPv6 lines and non-port targets.
    [[ "$line" == *"(v6)"* ]] && continue
    [[ "$target" =~ ^[0-9]+:[0-9]+(/(tcp|udp))?$ ]] || continue

    base="${target%%/*}"
    if [[ "$target" == */tcp ]]; then
      proto="tcp"
    elif [[ "$target" == */udp ]]; then
      proto="udp"
    else
      proto="both"
    fi

    if [[ -z "${seen[$base]:-}" ]]; then
      ranges+=("$base")
      seen["$base"]=1
      protos["$base"]=""
    fi

    case "$proto" in
      tcp)
        [[ "${protos[$base]}" == *tcp* ]] || protos["$base"]="${protos[$base]} tcp"
        ;;
      udp)
        [[ "${protos[$base]}" == *udp* ]] || protos["$base"]="${protos[$base]} udp"
        ;;
      both)
        protos["$base"]=" tcp udp"
        ;;
    esac
  done < <(awk '$2=="ALLOW" && $3=="IN" {print}' <<< "$ufw_status")

  if [[ ${#ranges[@]} -eq 0 ]]; then
    warn "No UFW port-range rule was found, for example 20000:60000/tcp."
    manual_port_wizard
    return
  fi

  echo
  echo "UFW port ranges found:"
  echo

  local i=1 label p
  for base in "${ranges[@]}"; do
    p="${protos[$base]}"
    if [[ "$p" == *tcp* && "$p" == *udp* ]]; then
      label="TCP + UDP"
    elif [[ "$p" == *tcp* ]]; then
      label="TCP"
    elif [[ "$p" == *udp* ]]; then
      label="UDP"
    else
      label="Unknown"
    fi

    printf "  %d) %-17s [%s]\n" "$i" "${base/:/-}" "$label"
    ((i++))
  done

  echo
  echo "  M) Enter a range manually"
  echo
  echo "You can select more than one range, for example: 1,2"
  echo

  local answer
  read -r -p "Select ranges to protect [1]: " answer
  answer="${answer:-1}"

  if [[ "$answer" =~ ^[Mm]$ ]]; then
    manual_port_wizard
    return
  fi

  IFS=',' read -ra selected <<< "$answer"

  local -a tcp_items=()
  local -a udp_items=()
  local idx nft_range

  for idx in "${selected[@]}"; do
    idx="${idx//[[:space:]]/}"

    [[ "$idx" =~ ^[0-9]+$ ]] || die "Selection '$idx' is not a valid number."
    (( idx >= 1 && idx <= ${#ranges[@]} )) || die "Selection '$idx' is outside the list."

    base="${ranges[$((idx-1))]}"
    nft_range="${base/:/-}"
    p="${protos[$base]}"

    if [[ "$p" == *tcp* ]]; then
      tcp_items+=("$nft_range")
    fi
    if [[ "$p" == *udp* ]]; then
      udp_items+=("$nft_range")
    fi
  done

  if [[ ${#tcp_items[@]} -gt 0 ]]; then
    TCP_PORT_SET="{ $(IFS=', '; echo "${tcp_items[*]}") }"
  fi

  if [[ ${#udp_items[@]} -gt 0 ]]; then
    UDP_PORT_SET="{ $(IFS=', '; echo "${udp_items[*]}") }"
  fi

  [[ -n "$TCP_PORT_SET" || -n "$UDP_PORT_SET" ]] || die "No protocol or range was selected."

  echo
  ok "Protection ranges selected from UFW."
  [[ -n "$TCP_PORT_SET" ]] && echo "  TCP : $TCP_PORT_SET"
  [[ -n "$UDP_PORT_SET" ]] && echo "  UDP : $UDP_PORT_SET"
}

manual_port_wizard() {
  local tcp_range udp_range default_tcp_set default_udp_set

  default_tcp_set='{ 20000-60000 }'
  default_udp_set='{ 20000-60000 }'

  echo
  echo -e "${C_YELLOW}Manual mode${C_RESET}"
  echo "Use nftables set format, for example:"
  echo "  { 25565-30000 }"
  echo "  { 19132, 20000-60000 }"
  echo
  echo "Enter '-' to leave a protocol unprotected."
  echo

  read -r -p "TCP port set [$default_tcp_set]: " tcp_range
  read -r -p "UDP port set [$default_udp_set]: " udp_range

  tcp_range="${tcp_range:-$default_tcp_set}"
  udp_range="${udp_range:-$default_udp_set}"

  [[ "$tcp_range" == "-" ]] && TCP_PORT_SET="" || TCP_PORT_SET="$tcp_range"
  [[ "$udp_range" == "-" ]] && UDP_PORT_SET="" || UDP_PORT_SET="$udp_range"

  [[ -n "$TCP_PORT_SET" || -n "$UDP_PORT_SET" ]] || die "TCP and UDP cannot both be disabled."
}

write_config() {
  local wan="$1" public_ip="$2" webhook="$3"

  cat > "$CONF" <<EOF
WAN="$wan"
PUBLIC_IP="$public_ip"
DISCORD_WEBHOOK="$webhook"

TCP_SYN_RATE="$TCP_SYN_RATE"
TCP_SYN_BURST="$TCP_SYN_BURST"

TCP_PACKET_RATE="$TCP_PACKET_RATE"
TCP_PACKET_BURST="$TCP_PACKET_BURST"

UDP_PACKET_RATE="$UDP_PACKET_RATE"
UDP_PACKET_BURST="$UDP_PACKET_BURST"

TCP_PORT_SET='$TCP_PORT_SET'
UDP_PORT_SET='$UDP_PORT_SET'
EOF

  chmod 600 "$CONF"
  ok "Configuration saved: $CONF"
}

write_guard() {
cat > "$BIN" <<'GUARD'
#!/usr/bin/env bash
set -Eeuo pipefail

CONF="/etc/ptero-guard.conf"
STATE_DIR="/run/ptero-guard"
TABLE="ptero_detect"

[[ -r "$CONF" ]] || { echo "Configuration $CONF was not found."; exit 1; }
# shellcheck disable=SC1091
source "$CONF"

mkdir -p "$STATE_DIR"

HOSTNAME_NOW="$(hostname)"

if [[ -z "${PUBLIC_IP:-}" ]]; then
  PUBLIC_IP="$(ip -4 -o addr show dev "$WAN" scope global |
    awk 'NR==1 {split($4,a,"/"); print a[1]}')"
fi

generate_rules() {
cat <<NFT
destroy table netdev ptero_detect

table netdev ptero_detect {
    set tcp_syn_rate {
        type inet_service
        flags dynamic,timeout
        timeout 10s
        size 65535
    }

    set tcp_packet_rate {
        type inet_service
        flags dynamic,timeout
        timeout 10s
        size 65535
    }

    set udp_rate {
        type inet_service
        flags dynamic,timeout
        timeout 10s
        size 65535
    }

    set attacked_tcp_syn {
        type inet_service
        flags dynamic,timeout
        timeout 60s
        size 65535
    }

    set attacked_tcp_packet {
        type inet_service
        flags dynamic,timeout
        timeout 60s
        size 65535
    }

    set attacked_udp {
        type inet_service
        flags dynamic,timeout
        timeout 60s
        size 65535
    }

    chain ingress {
        type filter hook ingress device "$WAN" priority -500;
        policy accept;
NFT

  if [[ -n "${TCP_PORT_SET:-}" ]]; then
    echo "        tcp dport $TCP_PORT_SET tcp flags & (fin|syn|rst|ack) == syn update @tcp_syn_rate { tcp dport limit rate over $TCP_SYN_RATE/second burst $TCP_SYN_BURST packets } update @attacked_tcp_syn { tcp dport timeout 60s } counter drop"
    echo
    echo "        tcp dport $TCP_PORT_SET update @tcp_packet_rate { tcp dport limit rate over $TCP_PACKET_RATE/second burst $TCP_PACKET_BURST packets } update @attacked_tcp_packet { tcp dport timeout 60s } counter drop"
  fi

  if [[ -n "${UDP_PORT_SET:-}" ]]; then
    echo
    echo "        udp dport $UDP_PORT_SET update @udp_rate { udp dport limit rate over $UDP_PACKET_RATE/second burst $UDP_PACKET_BURST packets } update @attacked_udp { udp dport timeout 60s } counter drop"
  fi

cat <<'NFT'
    }
}
NFT
}

apply_firewall() {
  local tmp
  tmp="$(mktemp)"
  generate_rules > "$tmp"

  if ! nft -c -f "$tmp"; then
    rm -f "$tmp"
    logger -t ptero-guard "nftables syntax validation failed"
    return 1
  fi

  nft -f "$tmp"
  rm -f "$tmp"
  logger -t ptero-guard "Per-port protection loaded on $WAN"
}

ensure_firewall() {
  nft list table netdev "$TABLE" >/dev/null 2>&1 || apply_firewall
}

get_ports() {
  local set_name="$1"

  nft -j list set netdev "$TABLE" "$set_name" 2>/dev/null |
  jq -r '
    .nftables[]?
    | select(.set != null)
    | .set.elem[]?
    | if type == "number" then .
      elif type == "object" and has("elem") then
        if (.elem|type) == "number" then .elem
        elif (.elem|type) == "object" then (.elem.val // empty)
        else empty end
      elif type == "object" and has("val") then .val
      else empty end
  ' |
  grep -E '^[0-9]+$' |
  sort -n -u || true
}

discord_post() {
  local payload="$1"

  [[ -n "${DISCORD_WEBHOOK:-}" ]] || return 0

  curl --silent --show-error --fail --max-time 10 \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "$DISCORD_WEBHOOK" >/dev/null ||
  logger -t ptero-guard "Discord webhook failed"
}

send_attack() {
  local proto="$1" port="$2" attack_type="$3" threshold="$4" payload

  payload="$(jq -n \
    --arg node "$HOSTNAME_NOW" \
    --arg ip "$PUBLIC_IP" \
    --arg proto "$proto" \
    --arg port "$port" \
    --arg attack "$attack_type" \
    --arg threshold "$threshold" \
    '{
      username:"Pterodactyl Flood Guard",
      embeds:[{
        title:"🚨 Flood Attack Detected",
        description:"Per-port mitigation is actively dropping excess traffic.",
        color:15158332,
        fields:[
          {name:"Node",value:("`"+$node+"`"),inline:true},
          {name:"Public IP",value:("`"+$ip+"`"),inline:true},
          {name:"Target",value:("`"+$proto+"/"+$port+"`"),inline:true},
          {name:"Attack Type",value:$attack,inline:true},
          {name:"Threshold",value:$threshold,inline:true},
          {name:"Action",value:"Excess traffic is dropped only for this destination port.",inline:false}
        ],
        footer:{text:"Pterodactyl Per-Port Flood Protection"},
        timestamp:(now|todateiso8601)
      }]
    }')"

  discord_post "$payload"
  logger -t ptero-guard "ATTACK $proto/$port type=$attack_type"
}

send_recovered() {
  local proto="$1" port="$2" attack_type="$3" payload

  payload="$(jq -n \
    --arg node "$HOSTNAME_NOW" \
    --arg ip "$PUBLIC_IP" \
    --arg proto "$proto" \
    --arg port "$port" \
    --arg attack "$attack_type" \
    '{
      username:"Pterodactyl Flood Guard",
      embeds:[{
        title:"✅ Attack Mitigated",
        description:"Traffic has returned below the configured threshold.",
        color:3066993,
        fields:[
          {name:"Node",value:("`"+$node+"`"),inline:true},
          {name:"Public IP",value:("`"+$ip+"`"),inline:true},
          {name:"Target",value:("`"+$proto+"/"+$port+"`"),inline:true},
          {name:"Attack Type",value:$attack,inline:true},
          {name:"Status",value:"Normal",inline:true}
        ],
        footer:{text:"Pterodactyl Per-Port Flood Protection"},
        timestamp:(now|todateiso8601)
      }]
    }')"

  discord_post "$payload"
  logger -t ptero-guard "RECOVERED $proto/$port type=$attack_type"
}

check_attack_set() {
  local set_name="$1" proto="$2" attack_type="$3" threshold="$4"
  local current="$STATE_DIR/${set_name}.current"
  local previous="$STATE_DIR/${set_name}.previous"

  get_ports "$set_name" > "$current"
  touch "$previous"

  sort -n -u -o "$current" "$current"
  sort -n -u -o "$previous" "$previous"

  comm -13 "$previous" "$current" |
  while read -r port; do
    [[ -n "$port" ]] && send_attack "$proto" "$port" "$attack_type" "$threshold"
  done

  comm -23 "$previous" "$current" |
  while read -r port; do
    [[ -n "$port" ]] && send_recovered "$proto" "$port" "$attack_type"
  done

  cp "$current" "$previous"
}

monitor() {
  ensure_firewall
  logger -t ptero-guard "Ptero Guard started on $WAN ($PUBLIC_IP)"

  while true; do
    if nft list table netdev "$TABLE" >/dev/null 2>&1; then
      check_attack_set attacked_tcp_syn TCP "TCP SYN Flood" "> ${TCP_SYN_RATE} SYN/s"
      check_attack_set attacked_tcp_packet TCP "TCP Packet Flood" "> ${TCP_PACKET_RATE} packets/s"
      check_attack_set attacked_udp UDP "UDP Packet Flood" "> ${UDP_PACKET_RATE} packets/s"
    else
      logger -t ptero-guard "Firewall table missing; restoring"
      apply_firewall
    fi
    sleep 2
  done
}

test_webhook() {
  [[ -n "${DISCORD_WEBHOOK:-}" ]] || {
  echo "Discord notifications are not configured."
    exit 1
  }

  local payload

  payload="$(jq -n \
    --arg node "$HOSTNAME_NOW" \
    --arg ip "$PUBLIC_IP" \
    '{
      username:"Pterodactyl Flood Guard",
      embeds:[{
        title:"✅ Flood Guard Online",
        description:"Firewall protection and Discord notifications are active.",
        color:3066993,
        fields:[
          {name:"Node",value:("`"+$node+"`"),inline:true},
          {name:"Public IP",value:("`"+$ip+"`"),inline:true},
          {name:"Protection",value:"Per Destination Port",inline:true}
        ],
        footer:{text:"Pterodactyl Per-Port Flood Protection"},
        timestamp:(now|todateiso8601)
      }]
    }')"

  discord_post "$payload"
  echo "Webhook test sent."
}

status_guard() {
  echo "========================================"
  echo " PTERODACTYL FLOOD GUARD"
  echo "========================================"
  echo "Node : $HOSTNAME_NOW"
  echo "WAN  : $WAN"
  echo "IP   : $PUBLIC_IP"
  echo
  echo "TCP SYN     : $TCP_SYN_RATE/s"
  echo "TCP packets : $TCP_PACKET_RATE/s"
  echo "UDP packets : $UDP_PACKET_RATE/s"
  echo "TCP Ports   : ${TCP_PORT_SET:-Disabled}"
  echo "UDP Ports   : ${UDP_PORT_SET:-Disabled}"
  echo "Discord     : $([[ -n "${DISCORD_WEBHOOK:-}" ]] && echo Enabled || echo Disabled)"
  echo
  echo "[TCP SYN ATTACK]"
  nft list set netdev "$TABLE" attacked_tcp_syn 2>/dev/null || true
  echo
  echo "[TCP PACKET ATTACK]"
  nft list set netdev "$TABLE" attacked_tcp_packet 2>/dev/null || true
  echo
  echo "[UDP ATTACK]"
  nft list set netdev "$TABLE" attacked_udp 2>/dev/null || true
  echo
  echo "[DROP COUNTERS]"
  nft list chain netdev "$TABLE" ingress 2>/dev/null || true
}

case "${1:-monitor}" in
  monitor) monitor ;;
  apply) apply_firewall ;;
  test) test_webhook ;;
  status) status_guard ;;
  *) echo "Usage: ptero-guard {monitor|apply|test|status}"; exit 1 ;;
esac
GUARD

  chmod 700 "$BIN"
  bash -n "$BIN"
  ok "Ptero Guard binary created."
}

write_service() {
cat > "$SERVICE" <<'EOF'
[Unit]
Description=Pterodactyl Per-Port Flood Guard + Discord Notifications
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/ptero-guard monitor
Restart=always
RestartSec=3
User=root
RuntimeDirectory=ptero-guard
RuntimeDirectoryMode=0700

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "Systemd service created."
}

install_guard() {
  require_root
  detect_os

  clear || true
  echo -e "${C_BOLD}========================================"
  echo "       PTERO GUARD SETUP WIZARD"
  echo -e "========================================${C_RESET}"
  echo "Version $VERSION"
  echo

  install_deps

  local wan detected_ip input public_ip webhook node
  wan="$(detect_wan)"
  [[ -n "$wan" ]] || die "Unable to detect the WAN interface."

  detected_ip="$(detect_public_ip "$wan")"
  node="$(hostname)"

  echo
  info "Detected server:"
  echo "  Hostname  : $node"
  echo "  WAN       : $wan"
  echo "  IPv4      : ${detected_ip:-not detected}"
  echo

  if ask_yes_no "Use interface $wan?" "Y"; then
    :
  else
    read -r -p "Enter WAN interface: " input
    [[ -n "$input" ]] || die "WAN interface cannot be empty."
    wan="$input"
  fi

  public_ip="$detected_ip"
  if [[ -n "$detected_ip" ]]; then
    if ! ask_yes_no "Use IPv4 $detected_ip?" "Y"; then
      read -r -p "Enter public IPv4: " public_ip
    fi
  else
    read -r -p "Enter public IPv4: " public_ip
  fi

  discord_wizard "$node" "$public_ip"
  webhook="$DISCORD_WEBHOOK_SELECTED"

  port_wizard
  choose_profile

  echo
  echo -e "${C_BOLD}========================================"
  echo "         INSTALLATION CONFIRMATION"
  echo -e "========================================${C_RESET}"
  echo "Node              : $node"
  echo "WAN               : $wan"
  echo "Public IPv4       : $public_ip"
  echo "TCP Protected     : ${TCP_PORT_SET:-Disabled}"
  echo "UDP Protected     : ${UDP_PORT_SET:-Disabled}"
  echo "TCP SYN / port    : $TCP_SYN_RATE/s (burst $TCP_SYN_BURST)"
  echo "TCP PPS / port    : $TCP_PACKET_RATE/s (burst $TCP_PACKET_BURST)"
  echo "UDP PPS / port    : $UDP_PACKET_RATE/s (burst $UDP_PACKET_BURST)"
  echo "Discord           : $([[ -n "$webhook" ]] && echo Enabled || echo Disabled)"
  echo

  ask_yes_no "Is everything correct? Start installation?" "Y" || {
    warn "Installation cancelled."
    exit 0
  }

  backup_firewall
  write_config "$wan" "$public_ip" "$webhook"
  write_guard
  write_service

  info "Validating and applying nftables..."
  "$BIN" apply
  ok "nftables protection is active."

  systemctl enable --now ptero-guard.service
  sleep 1

  if ! systemctl is-active --quiet ptero-guard.service; then
    systemctl status ptero-guard.service --no-pager || true
    die "Service failed to start."
  fi

  ok "ptero-guard.service is active and persistent."

  echo
  echo -e "${C_GREEN}${C_BOLD}INSTALLATION COMPLETE${C_RESET}"
  echo
  echo "Commands:"
  echo "  ptero-guard status"
  echo "  ptero-guard test"
  echo "  journalctl -u ptero-guard -f"
  echo "  systemctl restart ptero-guard"
}

reconfigure_guard() {
  require_root
  [[ -x "$BIN" ]] || die "Ptero Guard is not installed."
  echo "For safety, run Install / Reinstall and complete the wizard again."
}

uninstall_guard() {
  require_root

  echo
  warn "This removes only Ptero Guard."
  echo "UFW and Docker rules will not be removed."
  echo

  ask_yes_no "Continue with uninstall?" "N" || exit 0

  systemctl disable --now ptero-guard.service 2>/dev/null || true
  rm -f "$SERVICE"
  systemctl daemon-reload
  nft destroy table netdev "$TABLE" 2>/dev/null || true
  rm -f "$BIN" "$CONF"
  rm -rf /run/ptero-guard

  ok "Ptero Guard was removed successfully."
}

main_menu() {
  require_root

  clear || true
  echo -e "${C_BOLD}========================================"
  echo "          PTERO GUARD INSTALLER"
  echo -e "========================================${C_RESET}"
  echo "Version: $VERSION"
  echo
  echo "1) Install / Reinstall"
  echo "2) Status"
  echo "3) Test Discord Webhook"
  echo "4) Restart Protection"
  echo "5) Uninstall"
  echo "6) Exit"
  echo

  read -r -p "Choose [1-6]: " choice

  case "$choice" in
    1) install_guard ;;
    2)
      [[ -x "$BIN" ]] || die "Ptero Guard is not installed."
      "$BIN" status
      ;;
    3)
      [[ -x "$BIN" ]] || die "Ptero Guard is not installed."
      "$BIN" test
      ;;
    4)
      systemctl restart ptero-guard.service
      systemctl status ptero-guard.service --no-pager
      ;;
    5) uninstall_guard ;;
    6) exit 0 ;;
    *) die "Invalid selection." ;;
  esac
}

main_menu
