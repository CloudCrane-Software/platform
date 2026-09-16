#!/usr/bin/env bash
# mem-watch.sh — daily memory snapshot for the co-located stack (ADR 0004 risk).
M=$(free | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
echo "$(date -Is) mem=${M}%" >> /opt/company/backups/mem-watch.log
(( M > 90 )) && { echo "$(date -Is) HIGH" >> /opt/company/backups/mem-watch.alert; docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' >> /opt/company/backups/mem-watch.alert; }
