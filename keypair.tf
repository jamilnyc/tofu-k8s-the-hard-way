# Generates the keypair used for SSH access to all 4 instances, so nothing has to be
# provided by hand.
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

# Registers the public half with AWS so it can be attached to the instances.
resource "aws_key_pair" "ssh" {
  key_name   = "k8s-hard-way"
  public_key = tls_private_key.ssh.public_key_openssh
}

# Writes the private half to disk so the operator can actually use it to SSH in.
resource "local_sensitive_file" "private_key" {
  filename        = "${path.module}/ssh/id_ed25519"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}
