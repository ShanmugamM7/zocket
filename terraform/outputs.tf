output "public_ip" {
  description = "Public IP of the EC2 instance."
  value       = aws_instance.app.public_ip
}

output "public_dns" {
  description = "Public DNS of the EC2 instance."
  value       = aws_instance.app.public_dns
}

output "bucket_name" {
  description = "S3 bucket for logs/artifacts."
  value       = aws_s3_bucket.artifacts.bucket
}

output "app_url" {
  description = "Base URL of the deployed app."
  value       = "http://${aws_instance.app.public_ip}:${var.app_port}"
}

output "ssh_command" {
  description = "Convenience SSH command."
  value = format(
    "ssh -i %s ubuntu@%s",
    var.public_key_path == "" ? abspath("${path.module}/generated_id_rsa") : abspath(replace(var.public_key_path, ".pub", "")),
    aws_instance.app.public_ip,
  )
}
