#!/usr/bin/env bash

set -euo pipefail

payload=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      payload="${2:-}"
      shift 2
      ;;
    *) shift ;;
  esac
done

if [ -n "${CURL_CAPTURE_FILE:-}" ]; then
  printf '%s' "$payload" > "$CURL_CAPTURE_FILE"
fi

if [ "${FAKE_CURL_FAIL:-0}" = "1" ]; then
  exit 22
fi

jq -n --arg content "${FAKE_CURL_CONTENT:-}" '{choices: [{message: {content: $content}}]}'
