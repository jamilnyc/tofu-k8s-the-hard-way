resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "ssh" {
  key_name   = "k8s-hard-way"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.module}/ssh/id_ed25519"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}
