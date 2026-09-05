#!/usr/bin/env bash
#
# Sets up a local kubeconfig on the operator's own machine (not the
# jumpbox), so `kubectl` can be run directly from a laptop instead of over
# SSH. Doc 10 (https://github.com/kelseyhightower/kubernetes-the-hard-way/
# blob/master/docs/10-configuring-kubectl.md) assumes the operator's own
# machine can already reach the API server; here it can't -- port 6443 is
# only open between the 4 cluster instances themselves (see main.tf), not
# to the operator's IP -- so this also opens an SSH tunnel through the
# jumpbox to bridge that gap.
#
# The jumpbox already has a self-contained-looking kubeconfig at
# /root/.kube/config (written by configure_kubectl_for_remote_access in
# jumpbox-setup.sh), but it only embeds the CA cert, not the admin client
# cert/key -- those are stored as absolute paths
# (/root/kubernetes-the-hard-way/admin.{crt,key}) that don't exist on this
# machine. So this script pulls those two files down separately and
# re-embeds them into the copy it keeps locally.
#
# Intended to be run from the operator's own machine, from the repo root
# (needs ./ssh/id_ed25519 and a working `tofu output`).
#
# Usage: ./local-kubeconfig-setup.sh [--start-tunnel]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SSH_KEY="${SCRIPT_DIR}/ssh/id_ed25519"
KUBE_DIR="${HOME}/.kube"
KUBECONFIG_LOCAL="${KUBE_DIR}/kthw-config"
HOSTS_ENTRY="127.0.0.1 server.kubernetes.local"

START_TUNNEL=false
for arg in "$@"; do
  case "$arg" in
    --start-tunnel) START_TUNNEL=true ;;
    *)
      echo "unknown option: $arg" >&2
      echo "usage: $0 [--start-tunnel]" >&2
      exit 1
      ;;
  esac
done

# Logs a start/end line around a step, same convention as
# jumpbox-setup.sh/hosts-setup.sh, so a failure is obvious about which step
# it happened in rather than just dumping a bare error.
run_step() {
  local desc=$1
  shift
  echo "[$(date -u +%FT%TZ)] START: ${desc}"
  if "$@"; then
    echo "[$(date -u +%FT%TZ)] OK: ${desc}"
  else
    local rc=$?
    echo "[$(date -u +%FT%TZ)] FAILED (exit ${rc}): ${desc}" >&2
    exit "${rc}"
  fi
}

get_jumpbox_ip() {
  JUMPBOX_IP=$(tofu output -json instance_public_ips | jq -r '.jumpbox')
  if [ -z "${JUMPBOX_IP}" ] || [ "${JUMPBOX_IP}" = "null" ]; then
    echo "could not read jumpbox public IP from 'tofu output' -- has 'tofu apply' been run?" >&2
    return 1
  fi
}

# /etc/hosts is only ever appended to, and only if the entry isn't already
# there -- re-running this script shouldn't pile up duplicate lines.
add_hosts_entry() {
  if grep -qxF "${HOSTS_ENTRY}" /etc/hosts 2>/dev/null; then
    echo "/etc/hosts already has '${HOSTS_ENTRY}', skipping"
    return 0
  fi
  echo "adding '${HOSTS_ENTRY}' to /etc/hosts (requires sudo)"
  echo "${HOSTS_ENTRY}" | sudo tee -a /etc/hosts >/dev/null
}

fetch_kubeconfig() {
  mkdir -p "${KUBE_DIR}"
  scp -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
    "root@${JUMPBOX_IP}:/root/.kube/config" "${KUBECONFIG_LOCAL}"
}

# admin.crt/admin.key aren't embedded in the jumpbox's kubeconfig (see
# header comment) -- pulled down as their own files and left in place
# afterward, not cleaned up, so they can be re-embedded again later (e.g.
# after the jumpbox is destroyed and rebuilt) without another round trip.
fetch_admin_certs() {
  scp -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
    "root@${JUMPBOX_IP}:/root/kubernetes-the-hard-way/admin.crt" \
    "root@${JUMPBOX_IP}:/root/kubernetes-the-hard-way/admin.key" \
    "${KUBE_DIR}/"
}

embed_admin_certs() {
  KUBECONFIG="${KUBECONFIG_LOCAL}" kubectl config set-credentials admin \
    --client-certificate="${KUBE_DIR}/admin.crt" \
    --client-key="${KUBE_DIR}/admin.key" \
    --embed-certs=true
}

# Foreground and blocking (-N, no remote command) -- left running until the
# operator Ctrl-C's it. "server" resolves on the jumpbox side (its own
# /etc/hosts, from hosts-setup.sh), not locally, so this works without this
# machine knowing the server's private IP.
start_tunnel() {
  echo "starting tunnel -- leave this running, Ctrl-C to stop"
  ssh -i "${SSH_KEY}" -N -L 6443:server:6443 "root@${JUMPBOX_IP}"
}

run_step "read jumpbox public IP from tofu output" get_jumpbox_ip
run_step "add server.kubernetes.local to /etc/hosts" add_hosts_entry
run_step "fetch kubeconfig from jumpbox" fetch_kubeconfig
run_step "fetch admin cert/key from jumpbox" fetch_admin_certs
run_step "embed admin cert/key into local kubeconfig" embed_admin_certs

echo
echo "Local kubeconfig ready at ${KUBECONFIG_LOCAL}"
echo "Run: export KUBECONFIG=${KUBECONFIG_LOCAL}"

if [ "${START_TUNNEL}" = true ]; then
  start_tunnel
else
  echo "Tunnel not started (pass --start-tunnel to open one), e.g.:"
  echo "  ssh -i ${SSH_KEY} -N -L 6443:server:6443 root@${JUMPBOX_IP}"
fi
