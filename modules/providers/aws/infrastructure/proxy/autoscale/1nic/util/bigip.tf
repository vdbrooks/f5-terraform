# Launches a Auto Scaled Group of BIG-IPs. 
# NOTE: 
#    * This is immutable, meaning that the configuration is managed entirely through the launch configuration.
#    * There is no DNS or ELB to dissagrate the traffic to these BIG-IPs.  


### VARIABLES ###

# TAGS
variable purpose        { default = "public"       }  
variable environment    { default = "dev"          }  
variable application    { default = "f5app"        }  
variable owner          { default = "f5owner"      }  
variable group          { default = "f5group"      } 
variable costcenter     { default = "f5costcenter" } 

# NETWORK:
variable region                 { default = "us-west-2"  }
variable availability_zones     { default = "us-west-2a,us-west-2b" }
variable vpc_id                 {}
variable subnet_ids             {}

# PROXY:
variable instance_type  { default = "m4.2xlarge" }
variable amis { 
    type = "map" 
    default = {
        "ap-northeast-1" = "ami-3b1e2f5c"
        "ap-northeast-2" = "ami-e0dc018e"
        "ap-southeast-1" = "ami-530eb430"
        "ap-southeast-2" = "ami-60d8d303"
        "eu-central-1"   = "ami-c24e91ad"
        "eu-west-1"      = "ami-1fbdb079"
        "sa-east-1"      = "ami-d58de1b9"
        "us-east-1"      = "ami-09721c1f"
        "us-east-2"      = "ami-3c183f59"
        "us-west-1"      = "ami-c46f49a4"
        "us-west-2"      = "ami-6bbd260b"
    }
}

## NETWORK
variable create_management_public_ip  { default = true }

# SYSTEM
variable dns_server           { default = "8.8.8.8" }
variable ntp_server           { default = "0.us.pool.ntp.org" }
variable timezone             { default = "UTC" }
variable management_gui_port  { default = "8443" }

# SECURITY
variable admin_username {}
variable admin_password {}

variable ssh_key_name        {}  # example "my-terraform-key"
variable restricted_src_address { default = "0.0.0.0/0" }

# NOTE certs not used below but keeping as optional input in case need to extend
variable site_ssl_cert  { default = "not-required-if-terminated-on-lb" }
variable site_ssl_key   { default = "not-required-if-terminated-on-lb" }

# APPLICATION
variable vs_dns_name      { default = "www.example.com" }
variable vs_address       { default = "0.0.0.0" }
variable vs_mask          { default = "0.0.0.0" }
variable vs_port          { default = "443" }

# SERVICE DISCOVERY
variable pool_member_port { default = "80" }
variable pool_name        { default = "www.example.com" }  # DNS (ex. "www.example.com") used to create fqdn node if there's no Service Discovery iApp 
variable pool_tag_key     { default = "Name" }
variable pool_tag_value   { default = "dev-www-instance" }

# Autoscale
variable scale_min      { default = 1 }
variable scale_max      { default = 3 }
variable scale_desired  { default = 1 }


### RESOURCES ###

provider "aws" {
  region = "${var.region}"
}

resource "aws_security_group" "sg" {
  name        = "${var.environment}-proxy-sg"
  description = "${var.environment}-proxy-ports"
  vpc_id      = "${var.vpc_id}"

  # MGMT ssh access 
  ingress {
    from_port   = 22 
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.restricted_src_address}"]
  }

  # MGMT HTTPS access 
  ingress {
    from_port   = "${var.management_gui_port}"
    to_port     = "${var.management_gui_port}"
    protocol    = "tcp"
    cidr_blocks = ["${var.restricted_src_address}"]
  }

  # VIP HTTP access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # VIP HTTPS access from anywhere
  ingress {
    from_port   = "${var.vs_port}"
    to_port     = "${var.vs_port}"
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ping access from internal
  ingress {
    from_port   = 8 
    to_port     = 0
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
      Name           = "${var.environment}-proxy-sg"
      environment    = "${var.environment}"
      owner          = "${var.owner}"
      group          = "${var.group}"
      costcenter     = "${var.costcenter}"
      application    = "${var.application}"
  }

}


resource "aws_iam_role_policy" "proxy_service_discovery_policy" {
  name = "proxy-service-discovery-policy"
  role = "${aws_iam_role.proxy_service_discovery_role.id}"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeAddresses",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeNetworkInterfaceAttributes",
        "ec2:DescribeRouteTables",
        "ec2:ReplaceRoute",
        "autoscaling:Describe*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
        "Effect": "Allow",
        "Action": [
            "cloudwatch:PutMetricData"
        ],
        "Resource": [
            "*"
        ]
    }
  ]
}
EOF
}

resource "aws_iam_role" "proxy_service_discovery_role" {
  name = "proxy-service-discovery-role"

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


resource "aws_iam_instance_profile" "proxy_service_discovery_profile" {
  name  = "proxy-service-discovery-profile"
  role = "${aws_iam_role.proxy_service_discovery_role.name}"
}



data "template_file" "user_data" {
  template = "${file("${path.module}/user_data.tpl")}"

  vars {
    admin_username        = "${var.admin_username}"
    admin_password        = "${var.admin_password}"
    management_gui_port   = "${var.management_gui_port}"
    dns_server            = "${var.dns_server}"
    ntp_server            = "${var.ntp_server}"
    timezone              = "${var.timezone}"
    region                = "${var.region}"
    application           = "${var.application}"
    vs_dns_name           = "${var.vs_dns_name}"
    vs_address            = "${var.vs_address}"
    vs_mask               = "${var.vs_mask}"
    vs_port               = "${var.vs_port}"
    pool_member_port      = "${var.pool_member_port}"
    pool_name             = "${var.pool_name}"
    pool_tag_key          = "${var.pool_tag_key}"
    pool_tag_value        = "${var.pool_tag_value}"
    site_ssl_cert         = "${var.site_ssl_cert}"
    site_ssl_key          = "${var.site_ssl_key}"
  }
}


resource "aws_launch_configuration" "proxy_lc" {
  name_prefix   = "${var.application}-proxy-lc-"
  key_name      = "${var.ssh_key_name}"
  image_id      = "${lookup(var.amis, var.region)}"
  instance_type = "${var.instance_type}"
  associate_public_ip_address = "${var.create_management_public_ip}"
  security_groups = ["${aws_security_group.sg.id}"]
  iam_instance_profile = "${aws_iam_instance_profile.proxy_service_discovery_profile.name}"
  user_data = "${data.template_file.user_data.rendered}"
  lifecycle {
    create_before_destroy = true
  }
}


resource "aws_autoscaling_group" "proxy_asg" {
  name                      = "${var.application}-${var.purpose}-proxy-asg"
  vpc_zone_identifier       = ["${split(",", var.subnet_ids)}"] 
  availability_zones        = ["${split(",", var.availability_zones)}"]
  max_size                  = 4
  min_size                  = 1
  health_check_grace_period = 300
  health_check_type         = "EC2"
  force_delete              = true
  launch_configuration      = "${aws_launch_configuration.proxy_lc.name}"
  tag {
    key = "Name"
    value = "${var.application}-${var.purpose}-proxy-asg"
    propagate_at_launch = true
  }

  tag {
    key = "environment"
    value = "${var.environment}"
    propagate_at_launch = true
  }

  tag {
    key = "owner"
    value = "${var.owner}"
    propagate_at_launch = true
  }

  tag {
    key = "group"
    value = "${var.group}"
    propagate_at_launch = true
  }

  tag {
    key = "costcenter"
    value = "${var.costcenter}"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "proxy_asg_policy" {
  name                   = "${var.application}-${var.purpose}-proxy-asg-policy"
  scaling_adjustment     = 2
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = "${aws_autoscaling_group.proxy_asg.name}"
}



### OUTPUTS ###


output "sg_id" { value = "${aws_security_group.sg.id}" }
output "sg_name" { value = "${aws_security_group.sg.name}" }

output "asg_id" { value = "${aws_autoscaling_group.proxy_asg.id}" }
output "asg_name" { value = "${aws_autoscaling_group.proxy_asg.name}" }

