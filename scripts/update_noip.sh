#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 -h HOSTNAME -u USER [-p PASS] [-s SERVICE_URL] [-i IP_PROVIDER]

Checks the A record of HOSTNAME with dig, compares it to the machine's
public IP, and updates No-IP (dynamic DNS) via HTTP if they differ.

Required:
  -h HOSTNAME     Hostname to check and update (e.g. myhost.ddns.net)
  -u USER         No-IP username

Optional:
  -p PASS         No-IP password (if omitted, will prompt interactively or
                  read from NOIP_PASS env var)
  -s SERVICE_URL  Update URL (default: https://dynupdate.no-ip.com/nic/update)
  -i IP_PROVIDER  Public IP provider URL (default: https://ifconfig.co/ip)
  -q              Quiet (only exit codes)
  -?              Show this help

Examples:
  $0 -h myhost.ddns.net -u me -p secret
  NOIP_PASS=secret $0 -h myhost.ddns.net -u me

EOF
}

HOST=""
USER=""
PASS=""
SERVICE_URL="https://dynupdate.no-ip.com/nic/update"
IP_PROVIDER="https://ifconfig.co/ip"
QUIET=0

while getopts ":h:u:p:s:i:q?" opt; do
  case "$opt" in
    h) HOST="$OPTARG" ;;
    u) USER="$OPTARG" ;;
    p) PASS="$OPTARG" ;;
    s) SERVICE_URL="$OPTARG" ;;
    i) IP_PROVIDER="$OPTARG" ;;
    q) QUIET=1 ;;
    ?) usage; exit 0 ;;
  esac
done

if [ -z "$HOST" ] || [ -z "$USER" ]; then
  usage
  exit 2
fi

# prefer PASS from env if not provided
if [ -z "${PASS:-}" ] && [ -n "${NOIP_PASS:-}" ]; then
  PASS="$NOIP_PASS"
fi

if [ -z "${PASS:-}" ]; then
  # read interactively without echo
  if [ -t 0 ]; then
    printf "No-IP password for %s: " "$USER" >&2
    read -r -s PASS
    printf "\n" >&2
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Error: password not provided and not interactive" >&2
    exit 3
  fi
fi

command -v dig >/dev/null 2>&1 || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] dig is required" >&2; exit 4; }
command -v curl >/dev/null 2>&1 || { echo "[$(date +"%Y-%m-%d %H:%M:%S")] curl is required" >&2; exit 5; }

# get A record from DNS
DOMAIN_IP=$(dig +short A "$HOST" | grep -Eo '^[0-9.]+' | head -n1 || true)
if [ -z "$DOMAIN_IP" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Could not determine A record for $HOST" >&2
  exit 6
fi

# get public IP
PUBLIC_IP=$(curl -fsS --max-time 10 "$IP_PROVIDER" | tr -d ' \n' || true)
if [ -z "$PUBLIC_IP" ]; then
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Could not determine public IP from $IP_PROVIDER" >&2
  exit 7
fi

if [ "$PUBLIC_IP" = "$DOMAIN_IP" ]; then
  [ "$QUIET" -eq 0 ] && echo "[$(date +"%Y-%m-%d %H:%M:%S")] No update needed: $HOST -> $PUBLIC_IP"
  exit 0
fi

# perform no-ip update
UA="ddclient-update-script/1.0 (+https://github.com/)"
RESPONSE=$(curl -fsS -u "$USER:$PASS" -A "$UA" --get --silent --show-error --retry 2 --retry-delay 2 \
  --max-time 20 "$SERVICE_URL" --data-urlencode "hostname=$HOST" --data-urlencode "myip=$PUBLIC_IP" | tr -d '\r') || {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Update request failed" >&2
  exit 8
}

if echo "$RESPONSE" | grep -Eiq "^(good|nochg)"; then
  [ "$QUIET" -eq 0 ] && echo "[$(date +"%Y-%m-%d %H:%M:%S")] Update successful: $HOST -> $PUBLIC_IP ($RESPONSE)"
  exit 0
else
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Update failed: $RESPONSE" >&2
  exit 9
fi
