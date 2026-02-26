locals {
  # Network configuration
  vpc_id   = "vpc-06ee282aacf654b7c"
  vpc_cidr = "10.206.0.0/16"
  private_subnets = {
    eu-west-1a = "subnet-0df8fab73b28be1d6"
    eu-west-1b = "subnet-02ce1a66b1b1f912f"
    eu-west-1c = "subnet-0e8fac954881a8fc9"
  }
}
