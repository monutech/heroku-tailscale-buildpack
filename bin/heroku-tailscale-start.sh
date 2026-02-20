#!/usr/bin/env bash

set -e

function log() {
  echo "-----> $*"
}

function indent() {
  sed -e 's/^/       /'
}

if [ -z "$TAILSCALE_AUTH_KEY" ]; then
  log "Skipping Tailscale"

else
  log "Starting Tailscale"

  if [ -z "$TAILSCALE_HOSTNAME" ]; then
    if [ -z "$HEROKU_APP_NAME" ]; then
      tailscale_hostname=$(hostname)
    else
      # Custom hostname logic: [APP_NAME]-[DYNO]
      # Clean dots from DYNO (web.1 -> web-1)
      SAFE_DYNO=${DYNO//./-}
      tailscale_hostname="${HEROKU_APP_NAME}-${SAFE_DYNO}"
    fi
  else
    tailscale_hostname="$TAILSCALE_HOSTNAME"
  fi
  log "Using Tailscale hostname=$tailscale_hostname"

  # Dynamically configure port
  TS_PORT=${TAILSCALE_PORT:-10527}
  TS_ACCEPT_DNS=${TAILSCALE_ACCEPT_DNS:-true}
  TS_ACCEPT_ROUTES=${TAILSCALE_ACCEPT_ROUTES:-true}
  TS_VERBOSE=${TAILSCALE_VERBOSE:-false}
  TS_EPHEMERAL=${TAILSCALE_EPHEMERAL:-true}
  
  # Update proxychains.conf
  if [ -n "${PROXYCHAINS_CONF_FILE:-}" ] && [ -f "$PROXYCHAINS_CONF_FILE" ]; then
    log "Configuring proxychains to use port $TS_PORT"
    # Set port
    sed -i "s/^socks5.*/socks5 127.0.0.1 $TS_PORT/" "$PROXYCHAINS_CONF_FILE"
    
    # Enable proxy_dns if MagicDNS is enabled
    if [ "$TS_ACCEPT_DNS" = "true" ]; then
      log "Enabling proxy_dns_daemon for MagicDNS"
      # We already enabled it in the config file, but let's ensure the daemon starts
    fi

    # Enable quiet_mode if not verbose
    if [ "$TS_VERBOSE" = "false" ]; then
      log "Silencing proxychains output"
      sed -i 's/^#quiet_mode/quiet_mode/' "$PROXYCHAINS_CONF_FILE"
    fi
  fi

  # Start tailscaled in background
  if [ "$TS_VERBOSE" = "true" ]; then
    TAILSCALED_LOG_CMD=""
  else
    TAILSCALED_LOG_CMD="> /dev/null 2>&1"
  fi

  # eval the command to handle the redirection properly
  eval "tailscaled -verbose ${TAILSCALED_VERBOSE:-0} --tun=userspace-networking --socks5-server=localhost:$TS_PORT --state=$HOME/.tailscale.state --socket=$HOME/tailscaled.sock $TAILSCALED_LOG_CMD &"
  
  EXTRA_FLAGS=""
  if [ -n "${TAILSCALE_LOGIN_SERVER:-}" ]; then
    EXTRA_FLAGS="$EXTRA_FLAGS --login-server=${TAILSCALE_LOGIN_SERVER}"
  fi

  until tailscale --socket=$HOME/tailscaled.sock up \
    --authkey=${TAILSCALE_AUTH_KEY} \
    --hostname="$tailscale_hostname" \
    $EXTRA_FLAGS \
    --accept-dns=$TS_ACCEPT_DNS \
    --accept-routes=$TS_ACCEPT_ROUTES \
    --advertise-exit-node=${TAILSCALE_ADVERTISE_EXIT_NODE:-false} \
    --shields-up=${TAILSCALE_SHIELDS_UP:-false}
  do
    log "Waiting for 5s for Tailscale to start"
    sleep 5
  done

  export ALL_PROXY=socks5://localhost:$TS_PORT/
  
  # Start proxychains4-daemon if configured
  if [ "$TS_ACCEPT_DNS" = "true" ]; then
    log "Starting proxychains4-daemon on 127.0.0.1:1053"
    proxychains4-daemon 127.0.0.1:1053 &
  fi

  log "Tailscale started"
fi
