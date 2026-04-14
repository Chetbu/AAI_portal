#!/bin/sh
# Runs as a background process inside the portal container.
# Reads config.json, checks each project's internal health endpoint,
# and writes results to status.json every 30 seconds.

CONFIG_FILE="/usr/share/nginx/html/config.json"
STATUS_FILE="/usr/share/nginx/html/status.json"

while true; do
    RESULT="{"
    FIRST=true

    PROJECTS=$(jq -r '.projects[] | @base64' "$CONFIG_FILE" 2>/dev/null)

    for PROJECT_B64 in $PROJECTS; do
        SLUG=$(echo "$PROJECT_B64" | base64 -d | jq -r '.slug')
        HEALTH_URL=$(echo "$PROJECT_B64" | base64 -d | jq -r '.healthInternal // empty')

        if [ -z "$HEALTH_URL" ]; then
            continue
        fi

        START_MS=$(date +%s%3N 2>/dev/null || echo "0")
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_URL" 2>/dev/null)
        END_MS=$(date +%s%3N 2>/dev/null || echo "0")

        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
            STATUS="up"
        else
            STATUS="down"
        fi

        RESPONSE_TIME=$((END_MS - START_MS))
        NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            RESULT="${RESULT},"
        fi

        RESULT="${RESULT}\"${SLUG}\":{\"status\":\"${STATUS}\",\"httpCode\":${HTTP_CODE},\"responseTimeMs\":${RESPONSE_TIME},\"lastCheck\":\"${NOW}\"}"
    done

    RESULT="${RESULT}}"

    echo "$RESULT" > "${STATUS_FILE}.tmp"
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

    sleep 30
done
