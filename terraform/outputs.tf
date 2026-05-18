output "ecr_repository_url" {
  description = "ECR repository URI — tag and push images here."
  value       = aws_ecr_repository.this.repository_url
}

output "alb_dns_name" {
  description = "ALB DNS name — point your domain CNAME/A-alias here."
  value       = aws_lb.this.dns_name
}

output "app_url" {
  description = "Application base URL."
  value       = "http://${aws_lb.this.dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for container logs."
  value       = aws_cloudwatch_log_group.ecs.name
}

output "ecr_push_commands" {
  description = "Commands to authenticate and push a Docker image to ECR."
  value       = <<-EOT
    # Authenticate
    aws ecr get-login-password --region ${var.aws_region} --profile ${var.aws_profile} \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.this.repository_url}

    # Build & push
    docker build -t ${aws_ecr_repository.this.repository_url}:latest /path/to/zocket
    docker push ${aws_ecr_repository.this.repository_url}:latest

    # Force new deployment after push
    aws ecs update-service \
      --cluster ${aws_ecs_cluster.this.name} \
      --service ${aws_ecs_service.this.name} \
      --force-new-deployment \
      --profile ${var.aws_profile} \
      --region ${var.aws_region}
  EOT
}
