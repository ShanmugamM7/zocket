variable "project" {
  description = "Project name; used as a prefix for resource names."
  type        = string
  default     = "task-tracker"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH (port 22) and reach monitoring (9090/3001/9100). Set to your own IP/32 in production."
  type        = string
  default     = "0.0.0.0/0"
}

variable "app_port" {
  description = "Port the application listens on inside the EC2 host."
  type        = number
  default     = 3000
}

variable "public_key_path" {
  description = "Optional path to an existing SSH public key. If empty, Terraform generates a new key pair and writes the private key to ./generated_id_rsa."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}
