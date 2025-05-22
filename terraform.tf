provider "aws" {
  region = "us-east-1" 
}

variable "key_name" {
  description = "Par de claves SSH para EC2"
  type        = string
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "CapstoneVPC"
  }
}

# Internet Gateway y attachment
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Subredes públicas
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnetA"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnetB"
  }
}

# Subredes privadas
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "PrivateSubnetA"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "PrivateSubnetB"
  }
}

# Elastic IP para NAT
resource "aws_eip" "nat" {
  domain = "vpc"
}

# NAT Gateway
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
}

# Tabla de rutas pública y asociación
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# Tabla de rutas privada y asociación
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# Zonas de disponibilidad
data "aws_availability_zones" "available" {}

##############################
# SECURITY GROUP PARA APP
##############################
resource "aws_security_group" "app_sg" {
  name        = "AppSG"
  description = "Acceso web y MySQL interno"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "MySQL interno"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "AppSG"
  }
}

##############################
# DB SUBNET GROUP
##############################
resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "capstonedbsubnetgroup"
  description = "Subredes privadas para RDS"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

##############################
# RDS INSTANCE
##############################
resource "aws_db_instance" "rds_instance" {
  identifier             = "capstone-rds"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  username               = "nodeapp"
  password               = "student12"
  db_name                = "STUDENTS"
  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
}

##############################
# LAUNCH TEMPLATE
##############################
data "template_file" "user_data" {
  template = <<EOF
#!/bin/bash -xe
apt update -y
apt install nodejs unzip wget npm mysql-client -y
wget https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCAP1-1-DEV/code.zip -P /home/ubuntu
cd /home/ubuntu
unzip code.zip -x "resources/codebase_partner/node_modules/*"
cd resources/codebase_partner
npm install aws aws-sdk
export APP_PORT=80
npm start &
echo '#!/bin/bash -xe
cd /home/ubuntu/resources/codebase_partner
export APP_PORT=80
npm start' > /etc/rc.local
chmod +x /etc/rc.local
EOF
}

resource "aws_launch_template" "app_template" {
  name_prefix   = "CapstoneAppTemplate"
  image_id      = "ami-0f9de6e2d2f067fca"
  instance_type = "t2.micro"
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data = base64encode(data.template_file.user_data.rendered)

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "AppInstance"
    }
  }
}

##############################
# TARGET GROUP
##############################
resource "aws_lb_target_group" "app_tg" {
  name        = "CapstoneTG"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

##############################
# LOAD BALANCER (ALB)
##############################
resource "aws_lb" "app_lb" {
  name               = "CapstoneALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.app_sg.id]
  subnets            = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]

  tags = {
    Name = "CapstoneALB"
  }
}

##############################
# LISTENER
##############################
resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

##############################
# AUTO SCALING GROUP
##############################
resource "aws_autoscaling_group" "app_asg" {
  name                      = "CapstoneASG"
  min_size                  = 1
  max_size                  = 3
  desired_capacity          = 1
  vpc_zone_identifier       = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]
  health_check_type         = "EC2"
  health_check_grace_period = 300
  target_group_arns         = [aws_lb_target_group.app_tg.arn]

  launch_template {
    id      = aws_launch_template.app_template.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "AutoAppInstance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

##############################
# INSTANCIA MANUAL (opcional)
##############################
data "template_file" "instance_user_data" {
  template = <<EOF
#!/bin/bash -xe
apt update -y
apt install nodejs unzip wget npm mysql-server -y
wget https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-200-ACCAP1-1/code.zip -P /home/ubuntu
cd /home/ubuntu
unzip code.zip -x "resources/codebase_partner/node_modules/*"
cd resources/codebase_partner
npm install aws aws-sdk
mysql -u root -e "CREATE USER 'nodeapp' IDENTIFIED WITH mysql_native_password BY 'student12'";
mysql -u root -e "GRANT all privileges on *.* to 'nodeapp'@'%';"
mysql -u root -e "CREATE DATABASE STUDENTS;"
mysql -u root -e "USE STUDENTS; CREATE TABLE students(
  id INT NOT NULL AUTO_INCREMENT,
  name VARCHAR(255) NOT NULL,
  address VARCHAR(255) NOT NULL,
  city VARCHAR(255) NOT NULL,
  state VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL,
  phone VARCHAR(100) NOT NULL,
  PRIMARY KEY ( id ));"
sed -i 's/.*bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl enable mysql
service mysql restart
export APP_DB_HOST=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
export APP_DB_USER=nodeapp
export APP_DB_PASSWORD=student12
export APP_DB_NAME=STUDENTS
export APP_PORT=80
npm start &
echo '#!/bin/bash -xe
cd /home/ubuntu/resources/codebase_partner
export APP_PORT=80
npm start' > /etc/rc.local
chmod +x /etc/rc.local
EOF
}

resource "aws_instance" "template_instance" {
  ami                    = "ami-0f9de6e2d2f067fca"
  instance_type          = "t2.micro"
  key_name               = var.key_name
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data = base64encode(data.template_file.instance_user_data.rendered)

  tags = {
    Name = "TemplateInstance"
  }
}
