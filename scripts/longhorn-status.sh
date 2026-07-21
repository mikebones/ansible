#!/usr/bin/env bash
# longhorn-status.sh — Longhorn state snapshot. Run from a node that has the
# cluster admin kubeconfig (rp5-0):
#   ssh mcostas@192.168.1.166 'KUBECONFIG=/etc/kubernetes/admin.conf sudo bash -s' < $0
#
# Shows the settings that control rebuild/salvage behaviour (auto-salvage,
# node-drain-policy, rebuild limits), the volume-robustness breakdown, Longhorn
# node readiness, and the list of degraded/faulted volumes — exactly the views
# used during the 1.30/1.31 hops to diagnose the unwanted rebuild churn.

: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
export KUBECONFIG
KC="kubectl -n longhorn-system"

echo "=== $(date -Is)  KUBECONFIG=${KUBECONFIG} ==="
echo

echo "=== key settings (rebuild / salvage behaviour) ==="
for s in auto-salvage node-drain-policy offline-replica-rebuilding \
         concurrent-replica-rebuild-per-node-limit replica-auto-balance \
         fast-replica-rebuild-enabled; do
  printf "%-42s = " "${s}"
  ${KC} get setting.longhorn.io "${s}" -o jsonpath='{.value}' 2>/dev/null \
    || echo "<missing>"
  echo
done
echo

echo "=== volume robustness breakdown ==="
${KC} get volumes.longhorn.io -o json 2>/dev/null \
  | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception as e: print("(no volumes / json err)",e); sys.exit()
from collections import Counter
c=Counter(v.get("status",{}).get("robustness","<none>") for v in d["items"])
for k,v in c.most_common(): print(f"  {k:14} {v}")
print("  TOTAL        %d"%sum(c.values()))'
echo

echo "=== Longhorn nodes (readiness) ==="
${KC} get nodes.longhorn.io -o custom-columns=NAME:.metadata.name,READY:.status.conditions\[\'Ready\'\].status,DISKS:.status.diskStats 2>/dev/null \
  || ${KC} get nodes.longhorn.io 2>/dev/null
echo

echo "=== non-healthy volumes (degraded / faulted / unknown) ==="
${KC} get volumes.longhorn.io -o json 2>/dev/null \
  | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for v in d["items"]:
  rob=v.get("status",{}).get("robustness","")
  if rob in ("degraded","faulted","unknown"):
    name=v["metadata"]["name"]
    attached=v.get("status",{}).get("attached",False)
    st=v.get("status",{}).get("state","")
    print(f"  {name:24} robustness={rob:9} state={st:10} attached={attached}")'
echo

echo "=== engine / instance-manager pods readiness ==="
${KC} get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,READY:.status.phase 2>/dev/null \
  | grep -E 'instance-manager|engine' | head -40
echo
echo "=== done ==="