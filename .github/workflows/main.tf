provider "aws" {
  region     = "eu-central-1"
  access_key = ""
  secret_key = ""
}

resource "aws_vpc" "test_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "test_gateway" {
  vpc_id = aws_vpc.test_vpc.id
}

resource "aws_route_table" "test_route_table" {
  vpc_id = aws_vpc.test_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.test_gateway.id
  }
}

resource "aws_subnet" "test_subnet_1" {
  vpc_id            = aws_vpc.test_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-central-1a"
  depends_on        = [aws_internet_gateway.test_gateway]
}

resource "aws_subnet" "test_subnet_2" {
  vpc_id            = aws_vpc.test_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-central-1b"
  depends_on        = [aws_internet_gateway.test_gateway]
}

resource "aws_route_table_association" "test_route_table_association_1" {
  subnet_id      = aws_subnet.test_subnet_1.id
  route_table_id = aws_route_table.test_route_table.id
}

resource "aws_route_table_association" "test_route_table_association_2" {
  subnet_id      = aws_subnet.test_subnet_2.id
  route_table_id = aws_route_table.test_route_table.id
}

resource "aws_security_group" "test_ec2_security_group" {
  name        = "Security Group for EC2"
  description = "Allow Web inbound traffic from ALB to EC2"
  vpc_id      = aws_vpc.test_vpc.id
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.test_vpc.cidr_block]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.test_vpc.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "test_ec2_bastion_host_security_group" {
  name        = "Security Group for EC2 bastion host"
  description = "Allow Web inbound traffic from Internet to EC2"
  vpc_id      = aws_vpc.test_vpc.id
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "test_alb_security_group" {
  name        = "Security Group for ALB"
  description = "Allow Web inbound traffic to ALB"
  vpc_id      = aws_vpc.test_vpc.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "test_alb" {
  name               = "test-ALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.test_alb_security_group.id]
  subnets            = [aws_subnet.test_subnet_1.id, aws_subnet.test_subnet_2.id]
}

resource "aws_lb_target_group" "test_alb_target_group" {
  name     = "test-ALB-Target-Group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.test_vpc.id
  health_check {
    path = "/"
    matcher = "200"
  }
}

resource "aws_lb_listener" "test_alb_listener_http" {
  load_balancer_arn = aws_lb.test_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.test_alb_target_group.arn
  }
}

/*
resource "aws_lb_listener" "test_alb_listener_https" {
  load_balancer_arn = aws_lb.test_alb.arn
  port              = "8090"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate_validation.cert_validation.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.test_alb_target_group.arn
  }
}
*/

resource "aws_instance" "test_EC2_bastion_host" {
  //need to somehow deliver Key pair for access to ALB managed instances
  ami = "ami-00f07845aed8c0ee7"
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.test_ec2_bastion_host_security_group.id]
  key_name = "key_pair"
  associate_public_ip_address = true
  subnet_id = aws_subnet.test_subnet_1.id
}

resource "aws_launch_configuration" "test_launch_config" {
  name = "test launch configuration"
  image_id = "ami-00f07845aed8c0ee7"
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.test_ec2_security_group.id]
  key_name = "key_pair"
  associate_public_ip_address = true //access to Net necessary to install httpd
  lifecycle {
    create_before_destroy = true
  }
  user_data = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y httpd
    sudo systemctl start httpd
    sudo systemctl enable httpd
    echo "<h1>Hello World from $(hostname -f)</h1>" > /var/www/html/index.html
    EOF
}


resource "aws_autoscaling_group" "test_autoscaling_group" {
  name = "test Autoscaling Group"
  launch_configuration = aws_launch_configuration.test_launch_config.id
  vpc_zone_identifier  = [aws_subnet.test_subnet_1.id, aws_subnet.test_subnet_2.id]
  min_size             = 2
  max_size             = 10
  desired_capacity     = 2
  health_check_type    = "ELB"
  target_group_arns    = [aws_lb_target_group.test_alb_target_group.arn]
}

resource "aws_autoscaling_policy" "test_avg_cpu_policy_greater" {
  name                   = "avg-cpu-policy-greater"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.test_autoscaling_group.id
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0
  }
}
 
resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.test_autoscaling_group.id
  lb_target_group_arn    = aws_lb_target_group.test_alb_target_group.arn
}

/*
resource "aws_acm_certificate" "ssl_cert" {
  domain_name       = "strona.dyles.com"
  validation_method = "DNS"
}

resource "aws_route53_record" "cert_validation" {
  zone_id = "Z3P5QSUBK4POTI" # Zastąp odpowiednim ID strefy Route 53 dla dyles.com
  name    = aws_acm_certificate.ssl_cert.domain_validation_options[0].resource_record_name
  type    = aws_acm_certificate.ssl_cert.domain_validation_options[0].resource_record_type
  ttl     = 60
  records = [aws_acm_certificate.ssl_cert.domain_validation_options[0].resource_record_value]
}

resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn         = aws_acm_certificate.ssl_cert.arn
  validation_record_fqdns = [aws_route53_record.cert_validation.fqdn]
}
*/
