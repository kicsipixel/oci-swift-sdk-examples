#!/usr/bin/env bash
#
# lb-security-rules.sh — ensure the VCN security rules an OCI Load Balancer needs
# to reach swift-oke pods on an OKE VIRTUAL-NODES cluster.
#
# On virtual nodes OKE never manages LB security rules for you (security-list
# management is always effectively "None"), and the LB's backends are the PODS
# reached as <pod-ip>:<NodePort>. The LB must be allowed to send both the traffic
# (TCP 30000-32767) and the health check (TCP 10256, externalTrafficPolicy:
# Cluster) to the node/pod subnet, and the world must reach the listeners
# (TCP 80/443). A wrong or missing health-check egress rule is invisible in the
# Service events but makes the LB flap: it works for ~30s after each reconcile,
# then marks the backends unhealthy and stops forwarding.
#
# This script discovers the Quick-Create subnets by display-name, then ensures
# these rules on their first security lists (idempotently — safe to re-run):
#
#   LB   subnet seclist  ingress  0.0.0.0/0        TCP 80
#   LB   subnet seclist  ingress  0.0.0.0/0        TCP 443
#   LB   subnet seclist  egress   <node-cidr>      TCP 30000-32767
#   LB   subnet seclist  egress   <node-cidr>      TCP 10256
#   node subnet seclist  ingress  <lb-cidr>        TCP 30000-32767
#   node subnet seclist  ingress  <lb-cidr>        TCP 10256
#
# Note: `oci network security-list update` REPLACES the whole rule array, so we
# fetch the current rules, merge in anything missing, and write the merged set
# back with --force. Requires: oci CLI, python3.
#
# Usage: ./lb-security-rules.sh <compartment-ocid> [--profile <name>]

set -euo pipefail

# --- args -------------------------------------------------------------------
COMPARTMENT=""
PROFILE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { echo "error: --profile needs a value" >&2; exit 2; }
      PROFILE_ARGS=(--profile "$2"); shift 2 ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)
      echo "error: unknown flag '$1'" >&2; exit 2 ;;
    *)
      [[ -z "$COMPARTMENT" ]] || { echo "error: unexpected argument '$1'" >&2; exit 2; }
      COMPARTMENT="$1"; shift ;;
  esac
done

if [[ -z "$COMPARTMENT" ]]; then
  echo "Usage: $0 <compartment-ocid> [--profile <name>]" >&2
  exit 2
fi

command -v oci     >/dev/null 2>&1 || { echo "error: oci CLI not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found on PATH" >&2; exit 1; }

log()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# --- discover subnets -------------------------------------------------------
log "Discovering OKE Quick-Create subnets in the compartment..."
SUBNETS_JSON="$(oci network subnet list --compartment-id "$COMPARTMENT" --all "${PROFILE_ARGS[@]}")"

eval "$(SUBNETS_JSON="$SUBNETS_JSON" python3 - <<'PY'
import json, os, shlex
data = json.loads(os.environ["SUBNETS_JSON"]).get("data", [])

def pick(prefix):
    for s in data:
        if str(s.get("display-name", "")).startswith(prefix):
            return s
    return None

lb   = pick("oke-svclbsubnet")
node = pick("oke-nodesubnet")

def emit(name, value):
    print(f'{name}={shlex.quote(str(value))}')

if not lb:
    print('DISCOVERY_ERROR=' + shlex.quote("no subnet matching oke-svclbsubnet-* found"))
elif not node:
    print('DISCOVERY_ERROR=' + shlex.quote("no subnet matching oke-nodesubnet-* found"))
else:
    lb_sl   = (lb.get("security-list-ids")   or [None])[0]
    node_sl = (node.get("security-list-ids") or [None])[0]
    if not lb_sl or not node_sl:
        print('DISCOVERY_ERROR=' + shlex.quote("a discovered subnet has no security list"))
    else:
        emit("LB_NAME",   lb.get("display-name"))
        emit("LB_CIDR",   lb.get("cidr-block"))
        emit("LB_SL",     lb_sl)
        emit("NODE_NAME", node.get("display-name"))
        emit("NODE_CIDR", node.get("cidr-block"))
        emit("NODE_SL",   node_sl)
PY
)"

if [[ -n "${DISCOVERY_ERROR:-}" ]]; then
  echo "error: $DISCOVERY_ERROR" >&2
  echo "       (this script targets the Quick-Create wizard's subnet naming)" >&2
  exit 1
fi

info "LB   subnet: $LB_NAME  ($LB_CIDR)"
info "             seclist $LB_SL"
info "node subnet: $NODE_NAME  ($NODE_CIDR)"
info "             seclist $NODE_SL"

# --- merge helper -----------------------------------------------------------
# ensure_rules <seclist-id> <ingress|egress> <desired-rules-json>
# Fetches the current rules for that direction, merges in any missing desired
# rule (matched on protocol + endpoint CIDR + TCP destination port range), and
# writes the merged set back only if something was added.
CHANGED=0
ensure_rules() {
  local sl_id="$1" direction="$2" desired="$3"
  local field
  if [[ "$direction" == "ingress" ]]; then field="ingress-security-rules"; else field="egress-security-rules"; fi

  local current
  current="$(oci network security-list get --security-list-id "$sl_id" "${PROFILE_ARGS[@]}" \
      --query "data.\"$field\"" 2>/dev/null || true)"
  [[ -n "$current" ]] || current="[]"

  local out_file added
  out_file="$(mktemp)"
  # python prints the number of rules added on stdout; human lines on stderr.
  # All data goes in via env vars — `python3 -` already uses stdin for the program.
  added="$(DIRECTION="$direction" DESIRED="$desired" CURRENT="$current" OUT_FILE="$out_file" \
    python3 - <<'PY'
import json, os, sys

direction = os.environ["DIRECTION"]
desired   = json.loads(os.environ["DESIRED"])
out_file  = os.environ["OUT_FILE"]
current   = json.loads(os.environ["CURRENT"])
endpoint  = "source" if direction == "ingress" else "destination"

def camel(k):
    p = k.split("-")
    return p[0] + "".join(w.capitalize() for w in p[1:])

def conv(o):
    if isinstance(o, dict):
        return {camel(k): conv(v) for k, v in o.items()}
    if isinstance(o, list):
        return [conv(x) for x in o]
    return o

def sig(rule):
    tcp = rule.get("tcpOptions") or {}
    dpr = tcp.get("destinationPortRange") or {}
    return (str(rule.get("protocol")), rule.get(endpoint), dpr.get("min"), dpr.get("max"))

# The get response uses hyphenated keys; update expects camelCase. Normalize
# everything to camelCase so the merged array is a single consistent shape.
merged = [conv(r) for r in current]
have   = {sig(r) for r in merged}

added = 0
for rule in desired:
    if sig(rule) in have:
        sys.stderr.write(f"    present: {rule['description']}\n")
        continue
    merged.append(rule)
    have.add(sig(rule))
    sys.stderr.write(f"    ADDING:  {rule['description']}\n")
    added += 1

with open(out_file, "w") as f:
    json.dump(merged, f)
print(added)
PY
)"

  if [[ "$added" -gt 0 ]]; then
    oci network security-list update --security-list-id "$sl_id" \
      --"$field" "file://$out_file" --force "${PROFILE_ARGS[@]}" >/dev/null
    CHANGED=$((CHANGED + added))
  fi
  rm -f "$out_file"
}

# --- desired rules ----------------------------------------------------------
tcp_rule() { # <dir-key> <cidr> <type-key> <port-min> <port-max> <description>
  python3 - "$@" <<'PY'
import json, sys
dir_key, cidr, type_key, pmin, pmax, desc = sys.argv[1:7]
print(json.dumps({
    "protocol": "6",
    dir_key: cidr,
    type_key: "CIDR_BLOCK",
    "isStateless": False,
    "tcpOptions": {"destinationPortRange": {"min": int(pmin), "max": int(pmax)}},
    "description": desc,
}))
PY
}

log ""
log "LB subnet — ingress (listeners open to the internet):"
ensure_rules "$LB_SL" ingress "[$(
  tcp_rule source 0.0.0.0/0 sourceType 80  80  "swift-oke: allow HTTP to the LB listener"),$(
  tcp_rule source 0.0.0.0/0 sourceType 443 443 "swift-oke: allow HTTPS to the LB listener")]"

log "LB subnet — egress (traffic + health check to the pods):"
ensure_rules "$LB_SL" egress "[$(
  tcp_rule destination "$NODE_CIDR" destinationType 30000 32767 "swift-oke: allow LB to pod NodePorts"),$(
  tcp_rule destination "$NODE_CIDR" destinationType 10256 10256 "swift-oke: allow LB to pod health check (kube-proxy /healthz)")]"

log "node subnet — ingress (accept traffic + health check from the LB):"
ensure_rules "$NODE_SL" ingress "[$(
  tcp_rule source "$LB_CIDR" sourceType 30000 32767 "swift-oke: allow LB traffic to pod NodePorts"),$(
  tcp_rule source "$LB_CIDR" sourceType 10256 10256 "swift-oke: allow LB health check to pods")]"

log ""
if [[ "$CHANGED" -gt 0 ]]; then
  log "Done — added $CHANGED rule(s). Re-run to confirm it reports everything present."
else
  log "Done — all required rules were already present. No changes."
fi
