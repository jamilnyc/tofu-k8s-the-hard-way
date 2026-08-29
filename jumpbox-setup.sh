#!/usr/bin/env bash
#
# Runs the "Set Up The Jumpbox" steps from Kubernetes The Hard Way, in order:
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/02-jumpbox.md
#
# Intended to be run as root on the jumpbox instance itself (SSH in first).
# Runs unattended via cloud-init with no console attached, so every step
# logs when it starts and how it ended (see run_step below).

set -euo pipefail

# Logs a start/end line around a step so unattended runs (piped to a log
# file by cloud-init) show what ran, how long it took, and whether it
# failed -- without set -e killing the script before the failure is logged.
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

install_packages() {
  apt-get update
  apt-get -y install wget curl vim openssl git
}

clone_repo() {
  if [ ! -d kubernetes-the-hard-way ]; then
    git clone --depth 1 \
      https://github.com/kelseyhightower/kubernetes-the-hard-way.git
  fi
}

enter_repo_dir() {
  cd kubernetes-the-hard-way
}

show_download_list() {
  cat "downloads-${ARCH}.txt"
}

download_binaries() {
  wget -q --show-progress \
    --https-only \
    --timestamping \
    -P downloads \
    -i "downloads-${ARCH}.txt"
}

list_downloads() {
  ls -oh downloads
}

extract_binaries() {
  mkdir -p downloads/{client,cni-plugins,controller,worker}
  tar -xvf "downloads/crictl-v1.32.0-linux-${ARCH}.tar.gz" \
    -C downloads/worker/
  tar -xvf "downloads/containerd-2.1.0-beta.0-linux-${ARCH}.tar.gz" \
    --strip-components 1 \
    -C downloads/worker/
  tar -xvf "downloads/cni-plugins-linux-${ARCH}-v1.6.2.tgz" \
    -C downloads/cni-plugins/
  tar -xvf "downloads/etcd-v3.6.0-rc.3-linux-${ARCH}.tar.gz" \
    -C downloads/ \
    --strip-components 1 \
    "etcd-v3.6.0-rc.3-linux-${ARCH}/etcdctl" \
    "etcd-v3.6.0-rc.3-linux-${ARCH}/etcd"
  mv downloads/{etcdctl,kubectl} downloads/client/
  mv downloads/{etcd,kube-apiserver,kube-controller-manager,kube-scheduler} \
    downloads/controller/
  mv downloads/{kubelet,kube-proxy} downloads/worker/
  mv "downloads/runc.${ARCH}" downloads/worker/runc
}

cleanup_archives() {
  rm -rf downloads/*gz
}

make_executable() {
  chmod +x downloads/{client,cni-plugins,controller,worker}/*
}

install_kubectl() {
  cp downloads/client/kubectl /usr/local/bin/
}

verify_kubectl() {
  kubectl version --client
}

run_step "install command line utilities" install_packages
run_step "clone kubernetes-the-hard-way repo" clone_repo
run_step "enter kubernetes-the-hard-way directory" enter_repo_dir

ARCH=$(dpkg --print-architecture)
echo "Detected architecture: ${ARCH}"

run_step "show download list for ${ARCH}" show_download_list
run_step "download binaries" download_binaries
run_step "list downloaded files" list_downloads
run_step "extract and organize binaries" extract_binaries
run_step "remove archive files" cleanup_archives
run_step "make binaries executable" make_executable
run_step "install kubectl to /usr/local/bin" install_kubectl
run_step "verify kubectl installation" verify_kubectl
