environment          = "dev"
region               = "eu-west-1"
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
instance_type        = "t3.micro"
asg_min              = 1
asg_max              = 2
asg_desired          = 2
app_port             = 8080
nat_gateway_count    = 1
# ami_id passed via -var="ami_id=ami-xxx" at apply time
