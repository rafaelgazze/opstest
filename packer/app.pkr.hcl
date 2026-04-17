packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "app_version" {
  type    = string
  default = "snapshot"
}

source "amazon-ebs" "suchapp" {
  ami_name      = "suchapp-${var.app_version}-${formatdate("YYYYMMDDHHmmss", timestamp())}"
  instance_type = "t3.micro"
  region        = var.region

  source_ami_filter {
    filters = {
      name                = "amzn2-ami-hvm-*-x86_64-gp2"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ssh_username = "ec2-user"

  tags = {
    Name       = "suchapp-${var.app_version}"
    AppVersion = var.app_version
    BuildTime  = timestamp()
    ManagedBy  = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.suchapp"]

  provisioner "shell" {
    inline = [
      "sudo amazon-linux-extras enable corretto8",
      "sudo yum install -y java-11-amazon-corretto-headless",
      "java -version"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo yum install -y amazon-cloudwatch-agent"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/app",
      "sudo useradd -r -s /sbin/nologin suchapp || true"
    ]
  }

  provisioner "file" {
    source      = "../target/suchapp-0.0.1-SNAPSHOT.jar"
    destination = "/tmp/suchapp.jar"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/suchapp.jar /opt/app/suchapp.jar",
      "sudo chown suchapp:suchapp /opt/app/suchapp.jar",
      "sudo chmod 500 /opt/app/suchapp.jar"
    ]
  }

  provisioner "shell" {
    inline = [
      <<-EOF
      sudo tee /etc/systemd/system/suchapp.service > /dev/null <<'UNIT'
      [Unit]
      Description=SuchApp Spring Boot Application
      After=network.target

      [Service]
      Type=simple
      User=suchapp
      Group=suchapp
      WorkingDirectory=/opt/app
      ExecStart=/usr/bin/java -jar /opt/app/suchapp.jar --spring.config.location=/opt/app/application.properties
      Restart=on-failure
      RestartSec=10
      StandardOutput=journal
      StandardError=journal

      [Install]
      WantedBy=multi-user.target
      UNIT
      sudo systemctl daemon-reload
      sudo systemctl enable suchapp
      EOF
    ]
  }
}
