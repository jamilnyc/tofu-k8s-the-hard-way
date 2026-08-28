output "instance_public_ips" {
  description = "Public IP addresses by machine name"
  value       = { for name, inst in aws_instance.machine : name => inst.public_ip }
}

output "instance_private_ips" {
  description = "Private IP addresses by machine name"
  value       = { for name, inst in aws_instance.machine : name => inst.private_ip }
}

output "ssh_commands" {
  description = "Ready-to-paste SSH commands for each machine"
  value = {
    for name, inst in aws_instance.machine :
    name => "ssh -i ./ssh/id_ed25519 root@${inst.public_ip}"
  }
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = local_sensitive_file.private_key.filename
}
