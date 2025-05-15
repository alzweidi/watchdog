#!/bin/bash

set -e

### === CONFIG ===
PROJECT_DIR="$HOME/nockchain"
FOLLOWER_SESSION="nock-follower"
SMTP_EMAIL="79sends@gmail.com"
SMTP_PASSWORD="rfkfwalbaktmyqwl"
EMAIL_RECIPIENT="ibraheem9omar@gmail.com"
LOG_FILE="$PROJECT_DIR/watchdog.log"
SYNC_TIMEOUT_SEC=900  # 15 minutes

### === LOGGING SETUP ===
exec > >(tee -a "$LOG_FILE") 2>&1

### === FUNCTIONS ===

send_alert_email() {
  local SUBJECT="$1"
  local BODY="$2"
  local SERVER_IP=$(curl -s ifconfig.me)

  echo -e "Subject: $SUBJECT\n\n$BODY\n\nServer IP: $SERVER_IP" | msmtp "$EMAIL_RECIPIENT"
}

kill_follower() {
  echo "[ACTION] Killing follower node..."
  tmux kill-session -t "$FOLLOWER_SESSION" 2>/dev/null || true
  sleep 3
}

update_code() {
  echo "[ACTION] Updating repo and dependencies..."
  cd "$PROJECT_DIR"
  git pull origin main
  make install-hoonc
  make build-hoon-all
  make build
  echo "[ACTION] Code update complete."
}

start_follower() {
  echo "[ACTION] Starting follower node..."
  tmux new-session -d -s "$FOLLOWER_SESSION" "cd $PROJECT_DIR && make run-nockchain-follower"
  echo "[ACTION] Follower node started."
}

repair_cycle() {
  echo "[⚠️  FAILURE DETECTED] Starting repair cycle at $(date)"
  send_alert_email "❌ NockChain Follower Recovered" "Detected follower node failure. Auto-repair triggered."
  kill_follower
  update_code
  start_follower
  echo "[INFO] Repair cycle completed at $(date)"
}

### === WATCHDOG MAIN LOOP ===

echo "🟢 NockChain Watchdog started at $(date)"
LAST_GOOD_EPOCH=$(date +%s)

while true; do
  # Capture tmux logs for follower session
  SYNC_LOG=$(tmux capture-pane -pt $FOLLOWER_SESSION | grep "candidate block timestamp updated" | tail -n1 || true)

  if [ -n "$SYNC_LOG" ]; then
    SYNC_TIME=$(echo "$SYNC_LOG" | grep -oP '\(\K[0-9:]+')
    SYNC_EPOCH=$(date -d "$SYNC_TIME" +%s 2>/dev/null || echo 0)

    if [ $SYNC_EPOCH -gt $LAST_GOOD_EPOCH ]; then
      LAST_GOOD_EPOCH=$SYNC_EPOCH
      echo "[INFO] Follower sync active at $(date)"
    fi
  else
    echo "[WARN] No sync logs found in follower session."
  fi

  # Check if timeout exceeded
  NOW_EPOCH=$(date +%s)
  DIFF=$((NOW_EPOCH - LAST_GOOD_EPOCH))

  if [ $DIFF -gt $SYNC_TIMEOUT_SEC ]; then
    echo "[ERROR] Follower node stalled. No sync for $((DIFF / 60)) min."
    repair_cycle
    LAST_GOOD_EPOCH=$(date +%s)  # Reset timer after repair
  fi

  sleep 60  # Check every 60 seconds
done
