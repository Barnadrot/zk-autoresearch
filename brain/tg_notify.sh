#!/bin/bash
# Send a Telegram notification from the brain.
#
# Setup:
#   1. Create a bot via @BotFather, get the token
#   2. Get your chat ID (message the bot, check https://api.telegram.org/bot<TOKEN>/getUpdates)
#   3. Export TG_BOT_TOKEN and TG_CHAT_ID in your shell profile
#
# Usage:
#   bash brain/tg_notify.sh "Experiment finished: 3 keeps in 12 iterations"
#   bash brain/tg_notify.sh "$(cat /tmp/experiment_summary.txt)"

set -e

MESSAGE="${1:?Usage: tg_notify.sh \"message\"}"
TOKEN="${TG_BOT_TOKEN:?Set TG_BOT_TOKEN}"
CHAT_ID="${TG_CHAT_ID:?Set TG_CHAT_ID}"

curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d chat_id="${CHAT_ID}" \
  -d text="${MESSAGE}" \
  -d parse_mode="Markdown" \
  > /dev/null
