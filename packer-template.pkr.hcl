packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.1"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "project_name" {
  type        = string
  description = "Name of the project"
  default     = "packer-imagebuilder-poc"
}

variable "environment" {
  type        = string
  description = "Environment name"
  default     = "dev"
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "ap-south-1"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for Packer build"
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for Packer build"
}

variable "security_group_id" {
  type        = string
  description = "Security group ID for Packer build"
}

variable "instance_profile" {
  type        = string
  description = "IAM instance profile for Packer build"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for Packer build"
  default     = "t3.micro"
}

# Data source for base AMI
data "amazon-ami" "base" {
  filters = {
    name                = "amzn2-ami-hvm-*-x86_64-gp2"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
  most_recent = true
  owners      = ["amazon"]
  region      = var.region
}

source "amazon-ebs" "app" {
  ami_name      = "${var.project_name}-${var.environment}-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.region
  vpc_id        = var.vpc_id
  subnet_id     = var.subnet_id
  security_group_id = var.security_group_id
  
  source_ami    = data.amazon-ami.base.id
  ssh_username  = "ec2-user"
  iam_instance_profile = var.instance_profile
  
  ami_description = "Custom AMI built with Packer for ${var.project_name} ${var.environment}"
  
  tags = {
    Name        = "${var.project_name}-${var.environment}"
    Environment = var.environment
    BuildTool   = "Packer"
    BuiltBy     = "CodeBuild"
    BaseAMI     = "{{ .SourceAMI }}"
    BuildDate   = "{{timestamp}}"
  }
  
  # Enable enhanced networking and monitoring
  ena_support     = true
  sriov_support   = true
  
  # Set root volume
  launch_block_device_mappings {
    device_name = "/dev/xvda"
    volume_size = 20
    volume_type = "gp3"
    delete_on_termination = true
    encrypted = false
  }
}

build {
  name = "sample-app-build"
  sources = [
    "source.amazon-ebs.app"
  ]

  # Update system packages
  provisioner "shell" {
    inline = [
      "echo 'Starting system update...'",
      "sudo yum update -y",
      "echo 'System update completed'"
    ]
  }

  # Install Docker
  provisioner "shell" {
    inline = [
      "echo 'Installing Docker...'",
      "sudo yum install -y docker",
      "sudo systemctl start docker",
      "sudo systemctl enable docker",
      "sudo usermod -a -G docker ec2-user",
      "echo 'Docker installation completed'"
    ]
  }

  # Install Node.js
  provisioner "shell" {
    inline = [
      "echo 'Installing Node.js...'",
      "curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -",
      "sudo yum install -y nodejs",
      "echo 'Node.js version:' $(node --version)",
      "echo 'NPM version:' $(npm --version)",
      "echo 'Node.js installation completed'"
    ]
  }

  # Install additional packages
  provisioner "shell" {
    inline = [
      "echo 'Installing additional packages...'",
      "sudo yum install -y git awscli htop",
      "echo 'Additional packages installation completed'"
    ]
  }

  # Copy application files
  provisioner "file" {
    source      = "sample-app/"
    destination = "/tmp/sample-app/"
    except      = ["packer-template.pkr.hcl", "buildspec.yml", "deploy-buildspec.yml", "README.md"]
  }

  # Setup application
  provisioner "shell" {
    inline = [
      "echo 'Setting up application...'",
      "sudo mkdir -p /opt/app",
      "sudo cp -r /tmp/sample-app/* /opt/app/",
      "sudo chown -R ec2-user:ec2-user /opt/app",
      "cd /opt/app",
      "npm install --production",
      "echo 'Application setup completed'"
    ]
  }

  # Create systemd service
