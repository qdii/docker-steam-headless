#!/bin/bash
set -euo pipefail
umask 077

if [ "${WIREGUARD_ENABLED:-}" = "true" ]; then
  # Ensure boringtun is used for userspace implementation if wg-quick is called later
  export WG_QUICK_USERSPACE_IMPLEMENTATION="${WG_QUICK_USERSPACE_IMPLEMENTATION:-boringtun}"

  if ! command -v wg >/dev/null 2>&1; then
      echo "Error: wg command not found. Please ensure wireguard-tools is installed." >&2
      exit 1
  fi

  if ! command -v boringtun >/dev/null 2>&1 && ! command -v boringtun-cli >/dev/null 2>&1; then
      echo "Error: boringtun command not found. Please ensure boringtun is installed." >&2
      exit 1
  fi

  # Ensure cap_net_admin capability is set on boringtun
  if command -v setcap >/dev/null 2>&1; then
      setcap cap_net_admin+epi /usr/local/bin/boringtun-cli 2>/dev/null || true
  fi

  # Validate Port
  PORT="${WIREGUARD_PORT:-51820}"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( 10#$PORT < 1 )) || (( 10#$PORT > 65535 )); then
      echo "Error: WIREGUARD_PORT must be a valid integer between 1 and 65535. Got: '$PORT'" >&2
      exit 1
  fi

  # Validate Address
  ADDRESS="${WIREGUARD_ADDRESS:-10.13.13.1/24}"
  if ! [[ "$ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
      echo "Error: WIREGUARD_ADDRESS must be a valid IPv4 address or CIDR (e.g., 10.13.13.1/24). Got: '$ADDRESS'" >&2
      exit 1
  fi

  mkdir -p /etc/wireguard

  if [ -n "${WIREGUARD_PRIVATE_KEY:-}" ]; then
      PRIVATE_KEY="$WIREGUARD_PRIVATE_KEY"
  else
      PRIVATE_KEY=$(wg genkey)
  fi
  echo "$PRIVATE_KEY" >/etc/wireguard/privatekey

  PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
  echo "WireGuard Public Key: $PUBLIC_KEY"

  cat <<EOF >/etc/wireguard/wg0.conf
[Interface]
PrivateKey = $PRIVATE_KEY
ListenPort = $PORT
Address = $ADDRESS
EOF

  KEYS_STR=""
  IPS_STR=""
  if [ -n "${WIREGUARD_PEER_PUBLIC_KEYS:-}" ]; then
      KEYS_STR="$WIREGUARD_PEER_PUBLIC_KEYS"
      IPS_STR="${WIREGUARD_PEER_ALLOWED_IPS:-}"
  elif [ -n "${WIREGUARD_PEER_PUBLIC_KEY:-}" ]; then
      KEYS_STR="$WIREGUARD_PEER_PUBLIC_KEY"
      IPS_STR="${WIREGUARD_PEER_ALLOWED_IPS:-}"
  fi

  if [ -n "$KEYS_STR" ]; then
      # Determine delimiter: use ';' if present in WIREGUARD_PEER_ALLOWED_IPS, otherwise ','
      DELIM=","
      if [[ "$IPS_STR" == *";"* ]]; then
          DELIM=";"
      fi

      # Strip all whitespace from the input strings to prevent issues with spaces
      CLEAN_KEYS="${KEYS_STR//[[:space:]]/}"
      CLEAN_IPS="${IPS_STR//[[:space:]]/}"

      IFS="$DELIM" read -ra KEYS <<<"$CLEAN_KEYS"
      IFS="$DELIM" read -ra IPS <<<"$CLEAN_IPS"

      if [ "${#KEYS[@]}" -ne "${#IPS[@]}" ]; then
          echo "Error: The number of keys (${#KEYS[@]}) does not match the number of IPs (${#IPS[@]})." >&2
          exit 1
      fi

      for i in "${!KEYS[@]}"; do
          if [ -z "${KEYS[$i]}" ] || [ -z "${IPS[$i]}" ]; then
              echo "Error: Empty peer configuration detected (check for trailing delimiters or empty entries)." >&2
              exit 1
          fi
      cat <<EOF >>/etc/wireguard/wg0.conf
[Peer]
PublicKey = ${KEYS[$i]}
AllowedIPs = ${IPS[$i]}
EOF
      done
  fi

  chmod 600 /etc/wireguard/wg0.conf
fi
