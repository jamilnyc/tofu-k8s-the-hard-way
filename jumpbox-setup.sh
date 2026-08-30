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
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/08-bootstrapping-kubernetes-controllers.md
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/09-bootstrapping-kubernetes-workers.md
#
# The etcd steps are the doc's first ones that must run ON the server
# machine rather than the jumpbox. Rather than giving server its own
# independently-timed setup.sh/cloud-init (which would race jumpbox to
# finish -- see the "server-setup.sh + sleep" idea considered and rejected
# in favor of this), jumpbox stays the one orchestrator: it scp's the etcd
# binaries and unit file over exactly like it already does for certs and
# kubeconfigs, then ssh's in to run the remaining install/configure/start
# commands itself, in order, right after. No race, no separate script. Doc
# 08 (API server, controller manager, scheduler) follows the same shape,
# and so does doc 09 (worker nodes) -- just looped over node-0/node-1.
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

# The apiserver/controller-manager/scheduler binaries, their unit files, and
# the two configs they need (kube-scheduler.yaml, the RBAC manifest used
# later for kubelet access) all have to land on server before anything else
# in this section can run.
distribute_control_plane_binaries() {
  scp -o StrictHostKeyChecking=accept-new \
    downloads/controller/kube-apiserver \
    downloads/controller/kube-controller-manager \
    downloads/controller/kube-scheduler \
    downloads/client/kubectl \
    units/kube-apiserver.service \
    units/kube-controller-manager.service \
    units/kube-scheduler.service \
    configs/kube-scheduler.yaml \
    configs/kube-apiserver-to-kubelet.yaml \
    root@server:~/
}

# kube-scheduler.yaml gets moved here later; created up front since it
# doesn't exist on a fresh Debian install.
create_kubernetes_config_dir_on_server() {
  ssh "${SSH_OPTS[@]}" root@server 'mkdir -p /etc/kubernetes/config'
}

# Same PATH convention as etcd/kubectl before it: unit files' ExecStart
# lines expect these on /usr/local/bin.
install_control_plane_binaries_on_server() {
  ssh "${SSH_OPTS[@]}" root@server '
    mv kube-apiserver kube-controller-manager kube-scheduler kubectl \
      /usr/local/bin/
  '
}

# kube-apiserver.service points at /var/lib/kubernetes/ for the CA, its own
# serving cert, the service-account signing key pair (used to mint pod
# ServiceAccount tokens), and encryption-config.yaml (from doc 06) for
# encrypting Secrets at rest -- all have to be in place before it can start.
configure_kube_apiserver_on_server() {
  ssh "${SSH_OPTS[@]}" root@server '
    mkdir -p /var/lib/kubernetes/
    mv ca.crt ca.key \
      kube-api-server.key kube-api-server.crt \
      service-accounts.key service-accounts.crt \
      encryption-config.yaml \
      /var/lib/kubernetes/
  '
}

install_kube_apiserver_unit_on_server() {
  ssh "${SSH_OPTS[@]}" root@server \
    'mv kube-apiserver.service /etc/systemd/system/kube-apiserver.service'
}

# kube-controller-manager.service reads its kubeconfig (the identity it
# authenticates to the API server as) from /var/lib/kubernetes/, same
# directory as the apiserver's own state.
configure_kube_controller_manager_on_server() {
  ssh "${SSH_OPTS[@]}" root@server '
    mv kube-controller-manager.kubeconfig /var/lib/kubernetes/
    mv kube-controller-manager.service /etc/systemd/system/
  '
}

# kube-scheduler needs both its kubeconfig (identity) and kube-scheduler.yaml
# (its own component config, referencing that kubeconfig) in place before
# its unit file can start it.
configure_kube_scheduler_on_server() {
  ssh "${SSH_OPTS[@]}" root@server '
    mv kube-scheduler.kubeconfig /var/lib/kubernetes/
    mv kube-scheduler.yaml /etc/kubernetes/config/
    mv kube-scheduler.service /etc/systemd/system/
  '
}

# All three units were just installed, so systemd needs to reread them
# before enable/start will recognize them.
start_control_plane_on_server() {
  ssh "${SSH_OPTS[@]}" root@server '
    systemctl daemon-reload
    systemctl enable kube-apiserver \
      kube-controller-manager kube-scheduler
    systemctl start kube-apiserver \
      kube-controller-manager kube-scheduler
  '
}

# The doc calls out that kube-apiserver can take up to 10 seconds to finish
# initializing. Unlike the server-setup.sh timing race this script was
# designed to avoid, this is a short, doc-specified, single-process warm-up
# with no cross-instance boot-order uncertainty, so a fixed sleep is fine.
wait_for_kube_apiserver_startup() {
  sleep 10
}

# Confirms kube-apiserver actually reports active rather than just trusting
# "systemctl start" launched it -- a bad cert/config path shows up here.
verify_kube_apiserver_active() {
  ssh "${SSH_OPTS[@]}" root@server systemctl is-active kube-apiserver
}

# Confirms the whole control plane (not just kube-apiserver's own process
# state) is actually reachable and serving, using the admin identity the
# same way an operator would.
verify_cluster_info_on_server() {
  ssh "${SSH_OPTS[@]}" root@server \
    'kubectl cluster-info --kubeconfig admin.kubeconfig'
}

# Grants kube-apiserver the system:kube-apiserver-to-kubelet ClusterRole so
# it can reach the kubelet API on each worker node (metrics, logs, exec) --
# without this, features like `kubectl logs`/`kubectl exec` fail even
# though the control plane itself is healthy.
apply_kubelet_authorization_rbac() {
  ssh "${SSH_OPTS[@]}" root@server \
    'kubectl apply -f kube-apiserver-to-kubelet.yaml --kubeconfig admin.kubeconfig'
}

# Run from the jumpbox rather than over ssh, using the cluster's public DNS
# name and its own copy of ca.crt -- confirms the API server is reachable
# from outside server itself, not just over the loopback admin.kubeconfig
# uses above.
verify_control_plane_from_jumpbox() {
  curl --cacert ca.crt https://server.kubernetes.local:6443/version
}

# The bridge CNI config and kubelet config are per-host: each worker gets
# its own slice of the pod CIDR range from machines.txt (field 4), so the
# SUBNET placeholder in each template has to be filled in before that
# host's copy is sent -- sed re-renders both files fresh on every loop
# iteration so node-0 and node-1 never get each other's subnet.
distribute_worker_node_configs() {
  for host in node-0 node-1; do
    local subnet
    subnet=$(grep "${host}" machines.txt | cut -d " " -f 4)

    sed "s|SUBNET|${subnet}|g" configs/10-bridge.conf >10-bridge.conf
    sed "s|SUBNET|${subnet}|g" configs/kubelet-config.yaml >kubelet-config.yaml

    scp -o StrictHostKeyChecking=accept-new 10-bridge.conf kubelet-config.yaml \
      "root@${host}:~/"
  done
}

# Everything else a worker needs that *isn't* per-host: the runc/kubelet/
# kube-proxy/containerd binaries, kubectl, the remaining (non-templated)
# CNI/containerd/kube-proxy configs, and all three unit files.
distribute_worker_binaries() {
  for host in node-0 node-1; do
    scp -o StrictHostKeyChecking=accept-new \
      downloads/worker/* \
      downloads/client/kubectl \
      configs/99-loopback.conf \
      configs/containerd-config.toml \
      configs/kube-proxy-config.yaml \
      units/containerd.service \
      units/kubelet.service \
      units/kube-proxy.service \
      "root@${host}:~/"
  done
}

# Shipped into their own subdirectory (rather than $HOME alongside
# everything else above) since install_worker_binaries below needs to
# `mv cni-plugins/*` as one glob into /opt/cni/bin/.
distribute_worker_cni_plugins() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" mkdir -p cni-plugins

    scp -o StrictHostKeyChecking=accept-new downloads/cni-plugins/* \
      "root@${host}:~/cni-plugins/"
  done
}

# socat is what makes `kubectl port-forward` work; conntrack/ipset are
# runtime dependencies of kube-proxy's iptables rules; kmod provides
# modprobe, needed below to load br-netfilter.
install_worker_os_dependencies() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" '
      apt-get update
      apt-get -y install socat conntrack ipset kmod
    '
  done
}

# Kubernetes can't reliably account for pod memory usage if swap is in
# play, so it's turned off outright rather than conditionally checked --
# swapoff -a is already a no-op on a host where swap is off.
disable_swap_on_workers() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" swapoff -a
  done
}

# None of these exist on a fresh Debian install; every subsequent step on
# the worker (CNI config, binaries, kubelet/kube-proxy state) writes into
# one of these.
create_worker_install_dirs() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" '
      mkdir -p \
        /etc/cni/net.d \
        /opt/cni/bin \
        /var/lib/kubelet \
        /var/lib/kube-proxy \
        /var/lib/kubernetes \
        /var/run/kubernetes
    '
  done
}

# Same PATH convention used on server: crictl/kube-proxy/kubelet/runc go to
# /usr/local/bin; containerd's own pieces are installed to /bin instead,
# matching where its unit file and upstream tarball expect them; the CNI
# plugin binaries move out of the staging subdirectory from the distribute
# step above into the path containerd's CNI config points at.
install_worker_binaries() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" '
      mv crictl kube-proxy kubelet runc /usr/local/bin/
      mv containerd containerd-shim-runc-v2 containerd-stress /bin/
      mv cni-plugins/* /opt/cni/bin/
    '
  done
}

# Installs the per-host bridge config generated above plus the (identical
# on every host) loopback config, then loads br-netfilter and flips the two
# sysctls that make iptables actually see bridged traffic -- without this,
# traffic crossing the CNI bridge bypasses kube-proxy's iptables rules
# entirely.
configure_cni_networking_on_workers() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" '
      mv 10-bridge.conf 99-loopback.conf /etc/cni/net.d/
      modprobe br-netfilter
      echo "br-netfilter" >> /etc/modules-load.d/modules.conf
      echo "net.bridge.bridge-nf-call-iptables = 1" \
        >> /etc/sysctl.d/kubernetes.conf
      echo "net.bridge.bridge-nf-call-ip6tables = 1" \
        >> /etc/sysctl.d/kubernetes.conf
      sysctl -p /etc/sysctl.d/kubernetes.conf
    '
  done
}

# containerd.service points at /etc/containerd/config.toml by convention;
# the file shipped over is named containerd-config.toml specifically so it
# can't be confused with that final path while still in transit.
configure_containerd_on_workers() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" '
      mkdir -p /etc/containerd/
      mv containerd-config.toml /etc/containerd/config.toml
      mv containerd.service /etc/systemd/system/
    '
  done
}

# kubelet-config.yaml (already carrying this host's subnet from the
# distribute step above) is what kubelet.service's ExecStart references
# for its --config flag.
configure_kubelet_on_workers() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" '
      mv kubelet-config.yaml /var/lib/kubelet/
      mv kubelet.service /etc/systemd/system/
    '
  done
}

configure_kube_proxy_on_workers() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" '
      mv kube-proxy-config.yaml /var/lib/kube-proxy/
      mv kube-proxy.service /etc/systemd/system/
    '
  done
}

# All three units were just installed, so systemd needs to reread them
# before enable/start recognizes them -- same daemon-reload pattern used
# for etcd and the control plane services on server.
start_worker_services() {
  for host in node-0 node-1; do
    ssh "${SSH_OPTS[@]}" "root@${host}" '
      systemctl daemon-reload
      systemctl enable containerd kubelet kube-proxy
      systemctl start containerd kubelet kube-proxy
    '
  done
}

# Confirms kubelet actually came up on each worker rather than trusting
# "systemctl start" launched it -- same reasoning as verify_kube_apiserver_active.
# kubelet can sit in "activating" for a few seconds after systemctl start
# returns (containerd/CNI checks, first registration with the API server),
# and that delay isn't fixed -- so this polls is-active instead of sleeping
# a guessed duration, same condition-based-waiting pattern as wait_for_ssh
# in hosts-setup.sh. Fails loudly with the last-seen status if it never
# reaches active within the timeout, rather than racing ahead regardless.
verify_kubelet_active_on_workers() {
  for host in node-0 node-1; do
    local status
    status="unknown"
    for _ in $(seq 1 12); do
      status=$(ssh "${SSH_OPTS[@]}" "root@${host}" systemctl is-active kubelet || true)
      [ "${status}" = "active" ] && break
      sleep 5
    done

    echo "${host}: kubelet ${status}"
    if [ "${status}" != "active" ]; then
      echo "kubelet on ${host} did not become active in time (last status: ${status})" >&2
      return 1
    fi
  done
}

# The real end-to-end check: confirms the kubelets on node-0/node-1 have
# actually registered themselves with the API server on server and report
# Ready, not just that their local systemd units are active.
verify_worker_nodes_registered() {
  ssh "${SSH_OPTS[@]}" root@server \
    'kubectl get nodes --kubeconfig admin.kubeconfig'
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

run_step "distribute control plane binaries and configs to server" distribute_control_plane_binaries
run_step "create /etc/kubernetes/config on server" create_kubernetes_config_dir_on_server
run_step "install control plane binaries on server" install_control_plane_binaries_on_server
run_step "configure kube-apiserver on server" configure_kube_apiserver_on_server
run_step "install kube-apiserver systemd unit on server" install_kube_apiserver_unit_on_server
run_step "configure kube-controller-manager on server" configure_kube_controller_manager_on_server
run_step "configure kube-scheduler on server" configure_kube_scheduler_on_server
run_step "start control plane services on server" start_control_plane_on_server
run_step "wait for kube-apiserver to initialize" wait_for_kube_apiserver_startup
run_step "verify kube-apiserver is active" verify_kube_apiserver_active
run_step "verify cluster-info on server" verify_cluster_info_on_server
run_step "apply kubelet authorization RBAC" apply_kubelet_authorization_rbac
run_step "verify control plane version from jumpbox" verify_control_plane_from_jumpbox

run_step "distribute per-host worker configs" distribute_worker_node_configs
run_step "distribute worker binaries and configs" distribute_worker_binaries
run_step "distribute CNI plugins to workers" distribute_worker_cni_plugins
run_step "install worker OS dependencies" install_worker_os_dependencies
run_step "disable swap on workers" disable_swap_on_workers
run_step "create worker installation directories" create_worker_install_dirs
run_step "install worker binaries" install_worker_binaries
run_step "configure CNI networking on workers" configure_cni_networking_on_workers
run_step "configure containerd on workers" configure_containerd_on_workers
run_step "configure kubelet on workers" configure_kubelet_on_workers
run_step "configure kube-proxy on workers" configure_kube_proxy_on_workers
run_step "start worker services" start_worker_services
run_step "verify kubelet is active on workers" verify_kubelet_active_on_workers
run_step "verify worker nodes registered with cluster" verify_worker_nodes_registered
