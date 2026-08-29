#!/usr/bin/env bash
#
# Runs the "Setting Hostnames and Populating /etc/hosts" steps from
# Kubernetes The Hard Way, in order:
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/03-compute-resources.md
#
# Intended to be run as root on the jumpbox, once all 4 instances are up.
# Reads /root/machines.txt (written there by cloud-init -- see machines.tf)
# and needs root SSH access from the jumpbox to every IP listed in it.
#
# Runs unattended via cloud-init (see cloud-init.yaml), starting the moment
# the jumpbox itself finishes booting -- the other 3 nodes are booting in
# parallel and may not have sshd up yet, so wait_for_ssh below blocks until
# each one actually answers instead of racing them.

set -euo pipefail

MACHINES_FILE=${MACHINES_FILE:-/root/machines.txt}
HOSTS_FILE=${HOSTS_FILE:-/root/hosts}

# These are freshly created instances the jumpbox has never talked to before,
# so every connection trips an interactive host-key prompt; accept-new trusts
# it on first use instead of hanging a script with no console attached.
SSH_OPTS=(-n -o StrictHostKeyChecking=accept-new)

# Logs a start/end line around a step so unattended runs (piped to a log
# file) show what ran, how long it took, and whether it failed -- without
# set -e killing the script before the failure is logged.
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

wait_for_ssh() {
  while read -r IP FQDN HOST SUBNET; do
    for _ in $(seq 1 30); do
      ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes \
        "root@${IP}" true 2>/dev/null && continue 2
      sleep 10
    done
    echo "timed out waiting for ssh on ${HOST} (${IP})" >&2
    return 1
  done <"${MACHINES_FILE}"
}

set_remote_hostnames() {
  while read -r IP FQDN HOST SUBNET; do
    ssh "${SSH_OPTS[@]}" "root@${IP}" \
      "sed -i 's/^127.0.1.1.*/127.0.1.1\t${FQDN} ${HOST}/' /etc/hosts"
    ssh "${SSH_OPTS[@]}" "root@${IP}" hostnamectl set-hostname "${HOST}"
    ssh "${SSH_OPTS[@]}" "root@${IP}" systemctl restart systemd-hostnamed
  done <"${MACHINES_FILE}"
}

generate_hosts_file() {
  {
    echo ""
    echo "# Kubernetes The Hard Way"
    while read -r IP FQDN HOST SUBNET; do
      echo "${IP} ${FQDN} ${HOST}"
    done <"${MACHINES_FILE}"
  } >"${HOSTS_FILE}"
}

update_local_hosts() {
  cat "${HOSTS_FILE}" >>/etc/hosts
}

distribute_hosts_file() {
  # Deliberately targets each machine by HOST, not IP: update_local_hosts
  # just gave the jumpbox's own /etc/hosts real entries for these names, so
  # this doubles as confirmation that hostname resolution actually works.
  while read -r IP FQDN HOST SUBNET; do
    scp -o StrictHostKeyChecking=accept-new "${HOSTS_FILE}" "root@${HOST}:~/"
    ssh "${SSH_OPTS[@]}" "root@${HOST}" "cat ~/hosts >> /etc/hosts"
  done <"${MACHINES_FILE}"
}

run_step "wait for ssh on server and worker nodes" wait_for_ssh
run_step "set hostnames on server and worker nodes" set_remote_hostnames
run_step "generate local hosts file from ${MACHINES_FILE}" generate_hosts_file
run_step "append generated hosts file to jumpbox /etc/hosts" update_local_hosts
run_step "distribute hosts file to server and worker nodes" distribute_hosts_file
