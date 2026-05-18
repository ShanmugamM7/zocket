variable "project" {
  description = "Project name; used as prefix for all resource names."
  type        = string
  default     = "zocket"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use."
  type        = string
  default     = "PERSONAL"
}

variable "app_port" {
  description = "Port the container listens on."
  type        = number
  default     = 3000
}

variable "container_image" {
  description = "Full ECR image URI (e.g. 123456789.dkr.ecr.ap-south-1.amazonaws.com/zocket:v1.0.0). Defaults to ECR repo:latest when empty."
  type        = string
  default     = ""
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 / 512 / 1024 / 2048 / 4096)."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Number of ECS tasks to run."
  type        = number
  default     = 1
}

variable "health_check_path" {
  description = "ALB target group health check path."
  type        = string
  default     = "/healthz"
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS listener. Leave empty for HTTP-only (port 80 → TG)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}
