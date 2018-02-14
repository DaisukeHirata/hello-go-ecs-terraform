variable "environ" {default = "dh" }
variable "appname" {default = "app" }
variable "host_port" { default = 8080 }
variable "docker_port" { default = 8080 }
variable "nginx_host_port" { default = 80 }
variable "nginx_docker_port" { default = 80 }
variable "lb_port" { default = 80 }
variable "aws_region" { default = "ap-northeast-1" }
variable "key_name" { default = "YOUR-AWS-KEY-PAIR-NAME" }
variable "dockerimg" { default = "DOCKER_HUB_NAME/IMAGE_NAME" }
variable "nginx-dockerimg" { default = "DOCKER_HUB_NAME/IMAGE_NAME" }

# From https://github.com/aws/amazon-ecs-cli/blob/d566823dc716a83cf97bf93490f6e5c3c757a98a/ecs-cli/modules/config/ami/ami.go#L31
variable "ami" {
  description = "AWS ECS AMI id"
  default = {
    us-east-1 = "ami-67a3a90d"
    us-west-1 = "ami-b7d5a8d7"
    us-west-2 = "ami-c7a451a7"
    eu-west-1 = "ami-9c9819ef"
    eu-central-1 =  "ami-9aeb0af5"
    ap-northeast-1 = "ami-7e4a5b10"
    ap-southeast-1 = "ami-be63a9dd"
    ap-southeast-2 = "ami-b8cbe8db"
  }
}

provider "aws" {
  region = "${var.aws_region}"
}

module "vpc" {
  source = "github.com/terraform-aws-modules/terraform-aws-vpc"
  name = "${var.appname}-${var.environ}-vpc"
  cidr = "10.100.0.0/16"
  public_subnets = ["10.100.101.0/24", "10.100.102.0/24"]
  azs = ["ap-northeast-1a", "ap-northeast-1c"]
}

resource "aws_security_group" "allow_all_outbound" {
  name_prefix = "${var.appname}-${var.environ}-${module.vpc.vpc_id}-"
  description = "Allow all outbound traffic"
  vpc_id = "${module.vpc.vpc_id}"

  egress = {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "allow_all_inbound" {
  name_prefix = "${var.appname}-${var.environ}-${module.vpc.vpc_id}-"
  description = "Allow all inbound traffic"
  vpc_id = "${module.vpc.vpc_id}"

  ingress = {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "allow_cluster" {
  name_prefix = "${var.appname}-${var.environ}-${module.vpc.vpc_id}-"
  description = "Allow all traffic within cluster"
  vpc_id = "${module.vpc.vpc_id}"

  ingress = {
    from_port = 0
    to_port = 65535
    protocol = "tcp"
    self = true
  }

  egress = {
    from_port = 0
    to_port = 65535
    protocol = "tcp"
    self = true
  }
}

resource "aws_security_group" "allow_all_ssh" {
  name_prefix = "${var.appname}-${var.environ}-${module.vpc.vpc_id}-"
  description = "Allow all inbound SSH traffic"
  vpc_id = "${module.vpc.vpc_id}"

  ingress = {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# This role has a trust relationship which allows
# to assume the role of ec2
resource "aws_iam_role" "ecs" {
  name = "${var.appname}_ecs_${var.environ}"
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Action": "sts:AssumeRole",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Effect": "Allow",
        "Sid": ""
      }
    ]
  }
  EOF
}

# This is a policy attachement for the "ecs" role, it provides access
# to the the ECS service.
resource "aws_iam_policy_attachment" "ecs_for_ec2" {
  name = "${var.appname}_${var.environ}"
  roles = ["${aws_iam_role.ecs.id}"]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# This is the role for the load balancer to have access to ECS.
resource "aws_iam_role" "ecs_alb" {
  name = "${var.appname}_ecs_alb_${var.environ}"
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "",
        "Effect": "Allow",
        "Principal": {
          "Service": "ecs.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }
  EOF
}

# Attachment for the above IAM role.
resource "aws_iam_policy_attachment" "ecs_alb" {
  name = "${var.appname}_ecs_alb_${var.environ}"
  roles = ["${aws_iam_role.ecs_alb.id}"]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole"
}

# The ECS cluster
resource "aws_ecs_cluster" "cluster" {
    name = "${var.appname}_${var.environ}"
}

resource "template_file" "task_definition" {
  depends_on = ["null_resource.docker"]
  template = "${file("task-definition-nginx.json.tmpl")}"
  vars {
    nginx_name = "${var.appname}_nginx_${var.environ}"
    nginx_image = "${var.nginx-dockerimg}"
    nginx_docker_port = "${var.nginx_docker_port}"
    nginx_host_port = "${var.nginx_host_port}"
    internal_alb_host = "${aws_alb.service_alb_go.dns_name}"
    # this is so that task is always deployed when the image changes
    _img_id = "${null_resource.docker.id}"
  }
}

resource "template_file" "task_definition_go" {
  depends_on = ["null_resource.docker"]
  template = "${file("task-definition-go.json.tmpl")}"
  vars {
    name = "${var.appname}_${var.environ}"
    image = "${var.dockerimg}"
    docker_port = "${var.docker_port}"
    host_port = "${var.host_port}"
    # this is so that task is always deployed when the image changes
    _img_id = "${null_resource.docker.id}"
  }
}

resource "aws_ecs_task_definition" "ecs_task" {
  family = "${var.appname}_${var.environ}"
  network_mode = "bridge"
  container_definitions = "${template_file.task_definition.rendered}"
}

resource "aws_ecs_task_definition" "ecs_task_go" {
  family = "${var.appname}_${var.environ}"
  network_mode = "bridge"
  container_definitions = "${template_file.task_definition_go.rendered}"
}

resource "aws_alb" "service_alb" {
  name = "${var.appname}-${var.environ}"

  subnets = [
    "${element(module.vpc.public_subnets, 0)}", 
    "${element(module.vpc.public_subnets, 1)}"
  ]

  security_groups = [
    "${aws_security_group.allow_cluster.id}",
    "${aws_security_group.allow_all_inbound.id}",
    "${aws_security_group.allow_all_outbound.id}"
  ]

  internal                   = false
  enable_deletion_protection = false

  tags {
    Name        = "${var.appname}-${var.environ}"
    Environment = "Development"
    Type        = "ALB"
  }
}

resource "aws_alb" "service_alb_go" {
  name = "${var.appname}-${var.environ}-go"

  subnets = [
    "${element(module.vpc.public_subnets, 0)}", 
    "${element(module.vpc.public_subnets, 1)}"
  ]

  security_groups = [
    "${aws_security_group.allow_cluster.id}",
    "${aws_security_group.allow_all_inbound.id}",
    "${aws_security_group.allow_all_outbound.id}"
  ]

  internal                   = true
  enable_deletion_protection = false

  tags {
    Name        = "${var.appname}-${var.environ}-go"
    Environment = "Development"
    Type        = "ALB"
  }
}

resource "aws_alb_target_group" "service_alb" {
  name                 = "${var.appname}-${var.environ}"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = "${module.vpc.vpc_id}"
  deregistration_delay = 30

  health_check {
    interval            = 30
    path                = "/alive"
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 4
    matcher             = 200
  }

  tags {
    Name        = "${var.appname}-${var.environ}"
    Environment = "Development"
    Type        = "ALB"
  }
}

resource "aws_alb_target_group" "service_alb_go" {
  name                 = "${var.appname}-${var.environ}-go"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = "${module.vpc.vpc_id}"
  deregistration_delay = 30

  health_check {
    interval            = 30
    path                = "/alive"
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 4
    matcher             = 200
  }

  tags {
    Name        = "${var.appname}-${var.environ}-go"
    Environment = "Development"
    Type        = "ALB"
  }
}

resource "aws_alb_listener" "service_alb" {
  load_balancer_arn = "${aws_alb.service_alb.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.service_alb.arn}"
    type             = "forward"
  }
}

resource "aws_alb_listener" "service_alb_go" {
  load_balancer_arn = "${aws_alb.service_alb_go.arn}"
  port              = "8080"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.service_alb_go.arn}"
    type             = "forward"
  }
}

resource "aws_ecs_service" "ecs_service" {
  name = "${var.appname}_${var.environ}"
  cluster = "${aws_ecs_cluster.cluster.id}"
  task_definition = "${aws_ecs_task_definition.ecs_task.arn}"
  desired_count = 3
  iam_role = "${aws_iam_role.ecs_alb.arn}"
  depends_on = ["aws_iam_policy_attachment.ecs_alb"]
  deployment_minimum_healthy_percent = 50

  load_balancer {
    target_group_arn = "${aws_alb_target_group.service_alb.arn}"
    container_name = "${var.appname}_nginx_${var.environ}"
    container_port = "${var.nginx_docker_port}"
  }
}

resource "aws_ecs_service" "ecs_service_go" {
  name = "${var.appname}_${var.environ}_go"
  cluster = "${aws_ecs_cluster.cluster.id}"
  task_definition = "${aws_ecs_task_definition.ecs_task_go.arn}"
  desired_count = 3
  iam_role = "${aws_iam_role.ecs_alb.arn}"
  depends_on = ["aws_iam_policy_attachment.ecs_alb"]
  deployment_minimum_healthy_percent = 50

  load_balancer {
    target_group_arn = "${aws_alb_target_group.service_alb_go.arn}"
    container_name = "${var.appname}_${var.environ}"
    container_port = "${var.docker_port}"
  }
}

resource "aws_iam_instance_profile" "ecs" {
  name = "${var.appname}_${var.environ}"
  role = "${aws_iam_role.ecs.name}"
}

resource "aws_launch_configuration" "ecs_cluster" {
  name = "${var.appname}_cluster_conf_${var.environ}"
  instance_type = "t2.micro"
  image_id = "${lookup(var.ami, var.aws_region)}"
  iam_instance_profile = "${aws_iam_instance_profile.ecs.id}"
  associate_public_ip_address = true
  security_groups = [
    "${aws_security_group.allow_all_ssh.id}",
    "${aws_security_group.allow_all_outbound.id}",
    "${aws_security_group.allow_cluster.id}",
  ]
  user_data = "${file("userdata.sh")}"
  key_name = "${var.key_name}"
}

resource "aws_autoscaling_group" "ecs_cluster" {
  name = "${var.appname}_${var.environ}"
  vpc_zone_identifier = ["${element(module.vpc.public_subnets, 0)}", "${element(module.vpc.public_subnets, 1)}"]
  min_size = 0
  max_size = 3
  desired_capacity = 3
  launch_configuration = "${aws_launch_configuration.ecs_cluster.name}"
  health_check_type = "EC2"
}

resource "null_resource" "docker" {
  triggers {
    # This is a lame hack but it works
    log_hash = "${base64sha256(file("${path.module}/../.git/logs/HEAD"))}"
  }
  provisioner "local-exec" {
    command = "cd .. && docker build -t ${var.dockerimg} . && docker push ${var.dockerimg} && docker build . -f ./Dockerfile.nginx -t ${var.nginx-dockerimg} && docker push ${var.nginx-dockerimg}"
  }
}

resource "aws_cloudwatch_log_group" "fr-app-log" {
  name = "fr-app-log"
}

resource "aws_cloudwatch_log_group" "fr-nginx-log" {
  name = "fr-nginx-log"
}