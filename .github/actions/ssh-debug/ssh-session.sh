#!/bin/bash

SSHD_PID=$1
CLOUDFLARED_PID=$2
TIMEOUT=${3:-1800}

echo "SSH session will auto-cleanup after $TIMEOUT seconds"

# Wait for timeout or until processes die.
sleep "$TIMEOUT" &
SLEEP_PID=$!

# Monitor if SSH or cloudflared dies early.
while kill -0 "$SSHD_PID" 2>/dev/null && kill -0 "$CLOUDFLARED_PID" 2>/dev/null && kill -0 "$SLEEP_PID" 2>/dev/null; do
  sleep 10
done

# Cleanup.
kill "$SLEEP_PID" 2>/dev/null || true
kill "$SSHD_PID" 2>/dev/null || true
kill "$CLOUDFLARED_PID" 2>/dev/null || true

echo "SSH session ended"
