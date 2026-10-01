#!/bin/bash
# Grandin exposure proof (audit condition A3): Multica must answer ONLY on the
# Tailscale address. Every other address must refuse the connection.
# Usage: TAILNET_IP=100.x.y.z MULTICA_PORT=8780 bash check-exposure.sh
set -uo pipefail
P=${MULTICA_PORT:-8780}; fail=0
probe() { # $1 label, $2 url, $3 expect (open|refused)
  code=$(curl -s -o /dev/null -m 4 -w '%{http_code}' "$2"); rc=$?
  if [[ $3 == open ]]; then
    [[ $rc -eq 0 && $code != 000 ]] && echo "PASS  $1 answers ($code)  $2" || { echo "FAIL  $1 should answer  $2 (rc=$rc)"; fail=1; }
  else
    [[ $rc -ne 0 ]] && echo "PASS  $1 refused (curl rc=$rc)  $2" || { echo "FAIL  $1 ANSWERED $code  $2"; fail=1; }
  fi
}
probe "tailnet proxy"        "http://$TAILNET_IP:$P/api/config"        open
for ip in $(ifconfig | awk '/inet /{print $2}' | grep -v "^$TAILNET_IP$"); do
  probe "proxy port on $ip"  "http://$ip:$P/"        refused
  for raw in 3000 8080 5432; do
    [[ $ip == 127.0.0.1 ]] && continue   # loopback raw ports are expected (Compose binding)
    probe "raw :$raw on $ip" "http://$ip:$raw/"      refused
  done
done
echo "listeners:"; lsof -nP -iTCP:$P -iTCP:3000 -iTCP:8080 -iTCP:5432 -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print "  "$1, $9}' | sort -u
exit $fail
