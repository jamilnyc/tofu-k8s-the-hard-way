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

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = tls_private_key.ssh.public_key_openssh
  })

  tags = {
    Name = each.key
  }
}
