# KTHW's machines.txt lists just the server and worker nodes -- the jumpbox
# already has direct SSH access and doesn't need a DNS/hosts entry of its own.
#
# Sourced from var.machines rather than aws_instance.machine's attributes:
# the IPs are static input (each instance's private_ip is pinned to this same
# map in instances.tf, not AWS-assigned), and keeping this independent of the
# instances lets the jumpbox's own user_data embed the rendered file below
# without depending on itself -- a real cycle, since aws_instance.machine's
# for_each makes every instance, jumpbox included, a single dependency unit.
locals {
  machines_txt_entries = {
    for name, ip in var.machines : name => ip
    if name != "jumpbox"
  }
}

# Generated from var.machines on every apply instead of hand-maintained, so it
# can never drift from the private IPs actually assigned to each instance.
resource "local_file" "machines_txt" {
  filename = "${path.module}/machines.txt"
  content = templatefile("${path.module}/machines.txt.tftpl", {
    machines  = local.machines_txt_entries
    pod_cidrs = var.pod_cidrs
  })
}
