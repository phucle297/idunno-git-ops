output "secrets_manager_secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "flux_deploy_key_public_key_command" {
  value = "ssh-keygen -y -f <private-key-file>"
}
