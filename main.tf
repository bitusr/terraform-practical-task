terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "terraform-backend-practical-task" # bucket name
    key     = "terraform.tfstate"                # state file path
    region  = "eu-west-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "vpc-practical-task"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] # availability zones
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # to reduce costs
  enable_ipv6        = false
}

resource "aws_security_group" "practical_task_lb_public_access" {
  name   = "practical-task-lb-public-access"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }
}

resource "aws_security_group" "practical_task_ec2_sg" {
  name        = "practical-task-ec2-sg"
  vpc_id      = module.vpc.vpc_id
  description = "Allow HTTP traffic for the EC2 instances"
}

resource "aws_vpc_security_group_ingress_rule" "practical_task_ec2_lb_access" {
  security_group_id            = aws_security_group.practical_task_ec2_sg.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.practical_task_lb_public_access.id
}

resource "aws_vpc_security_group_egress_rule" "practical_task_ec2_internet_access" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.practical_task_ec2_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = each.value
  ip_protocol       = "tcp"
  to_port           = each.value
  tags = {
    Name = "internet access port ${each.value}"
  }
}

resource "aws_instance" "app" {
  count                       = 2
  ami                         = "ami-0df368112825f8d8f"
  instance_type               = "t2.micro"
  subnet_id                   = module.vpc.private_subnets[0]
  vpc_security_group_ids      = [aws_security_group.practical_task_ec2_sg.id]
  associate_public_ip_address = false
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/sh
    apt-get update
    apt-get install -y nginx-light
    echo 'Hello from instance app-${count.index}' > /var/www/html/index.html
  EOF

  tags = {
    Name = "app-${count.index}"
  }
}

resource "aws_elb" "app" {
  name            = "app"
  internal        = false
  security_groups = [aws_security_group.practical_task_lb_public_access.id]
  subnets         = module.vpc.public_subnets

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 10
    target              = "HTTP:80/"
  }

  cross_zone_load_balancing = true # to distribute traffic evenly across the zones

  tags = {
    Name = "app-classic-lb"
  }
}

resource "aws_elb_attachment" "app" {
  count    = length(aws_instance.app)
  elb      = aws_elb.app.id
  instance = aws_instance.app[count.index].id
}
