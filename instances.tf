# Resolves the latest Debian 12 AMI at apply time, so the AMI ID never goes stale.
data "aws_ami" "debian_12" {
  most_recent = true
  owners      = ["136693071363"]

  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# The 4 KTHW machines themselves (jumpbox, server, node-0, node-1) — one per
# entry in var.machines, each with root SSH enabled via cloud-init.
resource "aws_instance" "machine" {
  for_each = var.machines

  ami                    = data.aws_ami.debian_12.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = each.value
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.ssh.key_name

  associate_public_ip_address = true

  root_block_device {
    volume_size = var.root_volume_sizes[each.key]
    volume_type = "gp3"
  }

  # Any machine picks up a setup script automatically by convention: a file
  # named "<machine-name>-setup.sh" in the repo root (e.g. jumpbox-setup.sh
  # for the "jumpbox" entry in var.machines). It's passed as a template
  # variable (not read via a nested templatefile()) so its own "${...}" bash
  # expansions are never mistaken for HCL interpolation by the
  # templatefile() engine below.
  # machines_txt and ssh_private_key are only meaningful on the jumpbox: it's
  # the machine the KTHW docs ssh/scp to the other 3 nodes from (hosts-setup.sh),
  # which needs both /root/machines.txt to loop over and this cluster's private
  # key to actually authenticate as root on those nodes -- the other 3 only
  # ever receive inbound connections, so they don't need a copy.
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key     = trimspace(tls_private_key.ssh.public_key_openssh)
    setup_script       = fileexists("${path.module}/${each.key}-setup.sh") ? file("${path.module}/${each.key}-setup.sh") : ""
    machines_txt       = each.key == "jumpbox" ? local_file.machines_txt.content : ""
    ssh_private_key    = each.key == "jumpbox" ? tls_private_key.ssh.private_key_openssh : ""
    hosts_setup_script = each.key == "jumpbox" ? file("${path.module}/hosts-setup.sh") : ""
  })

  tags = {
    Name = each.key
  }
}
