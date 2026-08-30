#!/usr/bin/env bash
#
# Runs the "Set Up The Jumpbox", "Provisioning a CA and Generating TLS
# Certificates", "Generating Kubernetes Configuration Files for
# Authentication", "Generating the Data Encryption Config and Key", and
# "Bootstrapping the etcd Cluster" steps from Kubernetes The Hard Way, in
# order:
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/02-jumpbox.md
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/04-certificate-authority.md
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/05-kubernetes-configuration-files.md
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/06-data-encryption-keys.md
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/07-bootstrapping-etcd.md
#
# The etcd steps are the doc's first ones that must run ON the server
# machine rather than the jumpbox. Rather than giving server its own
# independently-timed setup.sh/cloud-init (which would race jumpbox to
# finish -- see the "server-setup.sh + sleep" idea considered and rejected
# in favor of this), jumpbox stays the one orchestrator: it scp's the etcd
# binaries and unit file over exactly like it already does for certs and
# kubeconfigs, then ssh's in to run the remaining install/configure/start
# commands itself, in order, right after. No race, no separate script.
#
# Intended to be run as root on the jumpbox instance itself (SSH in first).
# Runs unattended via cloud-init with no console attached, so every step
# logs when it starts and how it ended (see run_step below). cloud-init runs
# this after hosts-setup.sh (see cloud-init.yaml), since the certificate
# distribution steps below need to `ssh root@node-0` etc. by hostname.

set -euo pipefail

# Same reasoning as hosts-setup.sh: these are freshly created instances the
# jumpbox has never talked to before, so every connection trips an
# interactive host-key prompt; accept-new trusts it on first use instead of
# hanging a script with no console attached.
SSH_OPTS=(-n -o StrictHostKeyChecking=accept-new)

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
  # gettext-base provides envsubst, needed to render encryption-config.yaml.
  apt-get -y install wget curl vim openssl git gettext-base
}

enter_root_home() {
  cd /root
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

# Every non-CA certificate this cluster needs; each name doubles as the
# ca.conf section that supplies its identity (CN/O) and extensions.
CERTS=(
  "admin" "node-0" "node-1"
  "kube-proxy" "kube-scheduler"
  "kube-controller-manager"
  "kube-api-server"
  "service-accounts"
)

generate_ca() {
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -sha512 -noenc \
    -key ca.key -days 3653 \
    -config ca.conf \
    -out ca.crt
}

generate_certs() {
  for i in "${CERTS[@]}"; do
    openssl genrsa -out "${i}.key" 4096

    openssl req -new -key "${i}.key" -sha256 \
      -config "ca.conf" -section "${i}" \
      -out "${i}.csr"

    openssl x509 -req -days 3653 -in "${i}.csr" \
      -copy_extensions copyall \
      -sha256 -CA "ca.crt" \
      -CAkey "ca.key" \
      -CAcreateserial \
      -out "${i}.crt"
  done
}

distribute_worker_certs() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" mkdir -p /var/lib/kubelet/

    scp -o StrictHostKeyChecking=accept-new ca.crt "root@${host}:/var/lib/kubelet/"

    scp -o StrictHostKeyChecking=accept-new "${host}.crt" \
      "root@${host}:/var/lib/kubelet/kubelet.crt"

    scp -o StrictHostKeyChecking=accept-new "${host}.key" \
      "root@${host}:/var/lib/kubelet/kubelet.key"
  done
}

distribute_server_certs() {
  scp -o StrictHostKeyChecking=accept-new \
    ca.key ca.crt \
    kube-api-server.key kube-api-server.crt \
    service-accounts.key service-accounts.crt \
    root@server:~/
}

# Each kubeconfig bundles: which API server to trust (set-cluster), which
# identity to authenticate as (set-credentials), and the pairing of the two
# (set-context/use-context) -- all embedded so the resulting file is
# self-contained once copied off to the node/server that uses it.
generate_worker_kubeconfigs() {
  for host in node-0 node-1; do
    kubectl config set-cluster kubernetes-the-hard-way \
      --certificate-authority=ca.crt \
      --embed-certs=true \
      --server=https://server.kubernetes.local:6443 \
      --kubeconfig="${host}.kubeconfig"

    kubectl config set-credentials "system:node:${host}" \
      --client-certificate="${host}.crt" \
      --client-key="${host}.key" \
      --embed-certs=true \
      --kubeconfig="${host}.kubeconfig"

    kubectl config set-context default \
      --cluster=kubernetes-the-hard-way \
      --user="system:node:${host}" \
      --kubeconfig="${host}.kubeconfig"

    kubectl config use-context default \
      --kubeconfig="${host}.kubeconfig"
  done
}

generate_kube_proxy_kubeconfig() {
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://server.kubernetes.local:6443 \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-credentials system:kube-proxy \
    --client-certificate=kube-proxy.crt \
    --client-key=kube-proxy.key \
    --embed-certs=true \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-proxy \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config use-context default \
    --kubeconfig=kube-proxy.kubeconfig
}

generate_kube_controller_manager_kubeconfig() {
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://server.kubernetes.local:6443 \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-credentials system:kube-controller-manager \
    --client-certificate=kube-controller-manager.crt \
    --client-key=kube-controller-manager.key \
    --embed-certs=true \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-controller-manager \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config use-context default \
    --kubeconfig=kube-controller-manager.kubeconfig
}

generate_kube_scheduler_kubeconfig() {
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://server.kubernetes.local:6443 \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-credentials system:kube-scheduler \
    --client-certificate=kube-scheduler.crt \
    --client-key=kube-scheduler.key \
    --embed-certs=true \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-scheduler \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config use-context default \
    --kubeconfig=kube-scheduler.kubeconfig
}

# Points at 127.0.0.1 instead of server.kubernetes.local: this kubeconfig is
# meant to be used from the server node itself (kube-controller-manager and
# kube-scheduler run there too), not shipped to a remote client, so it talks
# to the local kube-apiserver directly -- still validated by ca.crt since
# 127.0.0.1 is one of kube-api-server.crt's SANs.
generate_admin_kubeconfig() {
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=admin.kubeconfig

  kubectl config set-credentials admin \
    --client-certificate=admin.crt \
    --client-key=admin.key \
    --embed-certs=true \
    --kubeconfig=admin.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=admin \
    --kubeconfig=admin.kubeconfig

  kubectl config use-context default \
    --kubeconfig=admin.kubeconfig
}

distribute_worker_kubeconfigs() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" mkdir -p /var/lib/{kube-proxy,kubelet}

    scp -o StrictHostKeyChecking=accept-new kube-proxy.kubeconfig \
      "root@${host}:/var/lib/kube-proxy/kubeconfig"

    scp -o StrictHostKeyChecking=accept-new "${host}.kubeconfig" \
      "root@${host}:/var/lib/kubelet/kubeconfig"
  done
}

distribute_control_kubeconfigs() {
  scp -o StrictHostKeyChecking=accept-new \
    admin.kubeconfig \
    kube-controller-manager.kubeconfig \
    kube-scheduler.kubeconfig \
    root@server:~/
}

# Not exported into a variable of its own since it's only ever read back out
# via $ENCRYPTION_KEY by envsubst below -- exporting it is what makes it
# visible to that child process at all (see the earlier envsubst debugging:
# a non-exported ENCRYPTION_KEY is invisible to envsubst even though $ENCRYPTION_KEY
# still echoes fine in this shell).
generate_encryption_key() {
  export ENCRYPTION_KEY
  ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
}

generate_encryption_config() {
  envsubst <configs/encryption-config.yaml \
    >encryption-config.yaml
}

distribute_encryption_config() {
  scp -o StrictHostKeyChecking=accept-new encryption-config.yaml root@server:~/
}

# etcd runs on server, not the jumpbox, so the binaries/unit file have to
# land there before any of the remaining steps can run against them.
distribute_etcd_binaries() {
  scp -o StrictHostKeyChecking=accept-new \
    downloads/controller/etcd \
    downloads/client/etcdctl \
    units/etcd.service \
    root@server:~/
}

# etcd.service's ExecStart expects the binaries on PATH at /usr/local/bin,
# matching where kubectl and the other components already get installed.
install_etcd_binaries_on_server() {
  ssh "${SSH_OPTS[@]}" root@server 'mv etcd etcdctl /usr/local/bin/'
}

# /etc/etcd holds the CA and kube-api-server cert/key etcd.service points
# at for peer/client TLS; /var/lib/etcd is etcd's data directory, chmod 700
# since it will hold the cluster's actual data once running.
configure_etcd_on_server() {
  ssh "${SSH_OPTS[@]}" root@server '
    mkdir -p /etc/etcd /var/lib/etcd
    chmod 700 /var/lib/etcd
    cp ca.crt kube-api-server.key kube-api-server.crt /etc/etcd/
  '
}

# systemd only manages units it finds in /etc/systemd/system, so the file
# scp'd to $HOME above has to move there before it's usable.
install_etcd_unit_on_server() {
  ssh "${SSH_OPTS[@]}" root@server 'mv etcd.service /etc/systemd/system/'
}

# daemon-reload picks up the unit file just installed; enable makes etcd
# survive a reboot, start actually brings it up now.
start_etcd_on_server() {
  ssh "${SSH_OPTS[@]}" root@server '
    systemctl daemon-reload
    systemctl enable etcd
    systemctl start etcd
  '
}

# Confirms etcd actually came up healthy as a single-node cluster, rather
# than trusting a "systemctl start" exit code that only means the process
# launched -- a bad cert path or config would still show up here.
verify_etcd_on_server() {
  ssh "${SSH_OPTS[@]}" root@server etcdctl member list
}

run_step "install command line utilities" install_packages
# cloud-init runs runcmd from /, not /root, so without this the repo clones
# to /kubernetes-the-hard-way instead of /root/kubernetes-the-hard-way.
run_step "enter /root" enter_root_home
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

run_step "generate certificate authority" generate_ca
run_step "generate and sign component certificates" generate_certs
run_step "distribute certs to node-0 and node-1" distribute_worker_certs
run_step "distribute certs to server" distribute_server_certs

run_step "generate node-0 and node-1 kubeconfigs" generate_worker_kubeconfigs
run_step "generate kube-proxy kubeconfig" generate_kube_proxy_kubeconfig
run_step "generate kube-controller-manager kubeconfig" generate_kube_controller_manager_kubeconfig
run_step "generate kube-scheduler kubeconfig" generate_kube_scheduler_kubeconfig
run_step "generate admin kubeconfig" generate_admin_kubeconfig
run_step "distribute kubeconfigs to node-0 and node-1" distribute_worker_kubeconfigs
run_step "distribute kubeconfigs to server" distribute_control_kubeconfigs

run_step "generate data encryption key" generate_encryption_key
run_step "generate encryption config" generate_encryption_config
run_step "distribute encryption config to server" distribute_encryption_config

run_step "distribute etcd binaries and unit file to server" distribute_etcd_binaries
run_step "install etcd binaries on server" install_etcd_binaries_on_server
run_step "configure etcd on server" configure_etcd_on_server
run_step "install etcd systemd unit on server" install_etcd_unit_on_server
run_step "start etcd on server" start_etcd_on_server
run_step "verify etcd cluster membership" verify_etcd_on_server
