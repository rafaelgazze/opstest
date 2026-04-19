environment   = "dev"
region        = "eu-west-1"
state_bucket  = "suchapp-terraform-state-<ACCOUNT_ID>"
instance_type = "t3.micro"
asg_min       = 1
asg_max       = 2
asg_desired   = 2
app_port      = 8080
# ami_id passed via -var="ami_id=ami-xxx" at apply time
