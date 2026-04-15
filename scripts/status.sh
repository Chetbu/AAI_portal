#!/bin/bash
# status.sh — quick AAI platform health overview
#
# Shows system resources, running containers, per-container resource usage,
# and which containers are attached to the aai-public network.

AAI_ROOT="${AAI_ROOT:-/opt/aai}"

echo "========================================="
echo "  AAI Platform Status"
echo "  $(date)"
echo "========================================="
echo ""

echo "── System ──────────────────────────────"
echo "  Uptime:  $(uptime -p)"
echo "  Load:    $(cut -d' ' -f1-3 /proc/loadavg)"
echo "  Memory:  $(free -h | awk '/^Mem:/{printf "%s / %s (%.0f%%)", $3, $2, $3/$2*100}')"
echo "  Disk:    $(df -h "${AAI_ROOT}" | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')"
echo ""

echo "── Containers ──────────────────────────"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | grep -E "^(NAMES|aai-)" || echo "  No aai-* containers running"
echo ""

echo "── Resources ───────────────────────────"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" | grep -E "^(NAME|aai-)" || echo "  No aai-* containers running"
echo ""

echo "── aai-public network ──────────────────"
docker network inspect aai-public --format '{{range .Containers}}  - {{.Name}}{{println}}{{end}}' 2>/dev/null || echo "  aai-public network not found"
