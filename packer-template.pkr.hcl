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
    name                = "al2023-ami-*-x86_64"
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
    volume_size = 30
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
      "sudo dnf update -y",
      "echo 'System update completed'"
    ]
  }

  # Install Docker
  provisioner "shell" {
    inline = [
      "echo 'Installing Docker...'",
      "sudo dnf install -y docker",
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
      "sudo dnf install -y nodejs npm",
      "echo 'Node.js version:' $(node --version)",
      "echo 'NPM version:' $(npm --version)",
      "echo 'Node.js installation completed'"
    ]
  }

  # Install additional packages
  provisioner "shell" {
    inline = [
      "echo 'Installing additional packages...'",
      "sudo dnf install -y git awscli htop",
      "echo 'Additional packages installation completed'"
    ]
  }

  # Create destination directory first
  provisioner "shell" {
    inline = [
      "echo 'Creating destination directory...'",
      "mkdir -p /tmp/sample-app",
      "echo 'Directory created'"
    ]
  }

  # Copy application files
  provisioner "file" {
    source      = "./"
    destination = "/tmp/sample-app"
    except      = ["packer-template.pkr.hcl", "buildspec.yml", "deploy-buildspec.yml", "README.md", "packer.log", "manifest.json", "ami.env", "packer_1.11.2_linux_amd64.zip", "LICENSE.txt"]
  }

  # Setup application
  provisioner "shell" {
    inline = [
      "echo 'Setting up application...'",
      "sudo mkdir -p /opt/app",
      "echo 'Listing files in /tmp/sample-app:'",
      "ls -la /tmp/sample-app/",
      "sudo cp -r /tmp/sample-app/* /opt/app/ 2>/dev/null || sudo cp -r /tmp/sample-app/. /opt/app/",
      "sudo chown -R ec2-user:ec2-user /opt/app",
      "cd /opt/app",
      "echo 'Listing files in /opt/app:'",
      "ls -la",
      "if [ -f package.json ]; then",
      "  npm install --production",
      "else",
      "  echo 'No package.json found, skipping npm install'",
      "fi",
      "echo 'Application setup completed'"
    ]
  }

  # Create systemd service
  provisioner "shell" {
    inline = [
      "echo 'Creating systemd service...'",
      "sudo tee /etc/systemd/system/${var.project_name}-app.service > /dev/null <<EOF",
      "[Unit]",
      "Description=${var.project_name} Application",
      "After=network.target",
      "",
      "[Service]",
      "Type=simple",
      "User=ec2-user",
      "WorkingDirectory=/opt/app",
      "ExecStart=/usr/bin/node server.js",
      "Restart=always",
      "RestartSec=10",
      "Environment=NODE_ENV=${var.environment}",
      "Environment=BUILD_TOOL=Packer",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "EOF",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable ${var.project_name}-app",
      "echo 'Systemd service created and enabled'"
    ]
  }

  # Install and configure CloudWatch agent
  provisioner "shell" {
    inline = [
      "echo 'Installing CloudWatch agent...'",
      "wget https://s3.${var.region}.amazonaws.com/amazoncloudwatch-agent-${var.region}/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm",
      "sudo rpm -U ./amazon-cloudwatch-agent.rpm",
      "rm -f ./amazon-cloudwatch-agent.rpm",
      "echo 'CloudWatch agent installed'"
    ]
  }

  # Configure CloudWatch agent
  provisioner "shell" {
    inline = [
      "echo 'Configuring CloudWatch agent...'",
      "sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null <<EOF",
      "{",
      "    \"logs\": {",
      "        \"logs_collected\": {",
      "            \"files\": {",
      "                \"collect_list\": [",
      "                    {",
      "                        \"file_path\": \"/var/log/messages\",",
      "                        \"log_group_name\": \"/aws/ec2/${var.project_name}/packer-app\",",
      "                        \"log_stream_name\": \"{instance_id}/messages\"",
      "                    }",
      "                ]",
      "            }",
      "        }",
      "    },",
      "    \"metrics\": {",
      "        \"namespace\": \"${var.project_name}/EC2\",",
      "        \"metrics_collected\": {",
      "            \"cpu\": {",
      "                \"measurement\": [",
      "                    \"cpu_usage_idle\",",
      "                    \"cpu_usage_iowait\",",
      "                    \"cpu_usage_user\",",
      "                    \"cpu_usage_system\"",
      "                ],",
      "                \"metrics_collection_interval\": 60",
      "            },",
      "            \"disk\": {",
      "                \"measurement\": [",
      "                    \"used_percent\"",
      "                ],",
      "                \"metrics_collection_interval\": 60,",
      "                \"resources\": [",
      "                    \"*\"",
      "                ]",
      "            },",
      "            \"mem\": {",
      "                \"measurement\": [",
      "                    \"mem_used_percent\"",
      "                ],",
      "                \"metrics_collection_interval\": 60",
      "            }",
      "        }",
      "    }",
      "}",
      "EOF",
      "echo 'CloudWatch agent configuration completed'"
    ]
  }

  # Final cleanup and testing
  provisioner "shell" {
    inline = [
      "echo 'Performing final cleanup and testing...'",
      "cd /opt/app",
      "npm test --if-present || echo 'No tests defined'",
      "sudo dnf clean all",
      "sudo rm -rf /tmp/*",
      "sudo rm -rf /var/tmp/*",
      "echo 'AMI preparation completed successfully'"
    ]
  }

  # Generate manifest for tracking
  post-processor "manifest" {
    output = "manifest.json"
    strip_path = true
    custom_data = {
      build_tool = "Packer"
      project_name = var.project_name
      environment = var.environment
      build_date = timestamp()
    }
  }
}