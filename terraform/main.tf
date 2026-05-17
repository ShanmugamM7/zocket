provider "aws" {
  region = var.aws_region
}

locals {
  name = var.project
  common_tags = merge(
    {
      Project   = var.project
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

# ---------------------------------------------------------------------------
# Networking — use the default VPC for simplicity
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------------------------------------------------------------------------
# AMI — latest Ubuntu 22.04 (Jammy) from Canonical
# ---------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ---------------------------------------------------------------------------
# SSH key — reuse user-provided key, otherwise generate one
# ---------------------------------------------------------------------------
resource "tls_private_key" "generated" {
  count     = var.public_key_path == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "private_key" {
  count           = var.public_key_path == "" ? 1 : 0
  content         = tls_private_key.generated[0].private_key_pem
  filename        = "${path.module}/generated_id_rsa"
  file_permission = "0600"
}

resource "aws_key_pair" "this" {
  key_name   = "${local.name}-key"
  public_key = var.public_key_path == "" ? tls_private_key.generated[0].public_key_openssh : file(var.public_key_path)
  tags       = local.common_tags
}

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${local.name}-sg"
  description = "Task Tracker — SSH, HTTP, app, and monitoring"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "App"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Prometheus UI"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "Grafana UI"
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "Node exporter"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    description = "Egress all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# S3 bucket for logs/artifacts
# ---------------------------------------------------------------------------
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-${random_id.bucket_suffix.hex}"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IAM — let the EC2 instance write to the bucket
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "s3_rw" {
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn]
  }
  statement {
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role_policy" "s3_rw" {
  name   = "${local.name}-s3-rw"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.s3_rw.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-instance-profile"
  role = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  key_name                    = aws_key_pair.this.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
              #!/bin/bash
              set -euxo pipefail
              apt-get update -y
              apt-get install -y python3 ca-certificates curl
              EOF

  tags = merge(local.common_tags, {
    Name = "${local.name}-ec2"
  })
}

# ---------------------------------------------------------------------------
# Generate an Ansible inventory file pointing at the new host
# ---------------------------------------------------------------------------
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"
  content         = <<-EOT
    [app]
    ${aws_instance.app.public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${var.public_key_path == "" ? abspath("${path.module}/generated_id_rsa") : abspath(replace(var.public_key_path, ".pub", ""))}

    [app:vars]
    artifacts_bucket=${aws_s3_bucket.artifacts.bucket}
    aws_region=${var.aws_region}
  EOT
}
