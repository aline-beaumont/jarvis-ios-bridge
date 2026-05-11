#!/bin/bash
# JARVIS Bridge Server launcher
# Set your API keys here or export them before running

export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
export JARVIS_PORT="${JARVIS_PORT:-8765}"

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "=== JARVIS Bridge Server ==="
echo "Port: $JARVIS_PORT"
echo "Anthropic API: ${ANTHROPIC_API_KEY:+configured}"
echo "OpenAI API: ${OPENAI_API_KEY:+configured}"
echo "==========================="

python3 jarvis_bridge_server.py
