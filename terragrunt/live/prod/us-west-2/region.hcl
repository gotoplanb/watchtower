# prod / us-west-2 (Watchtower).
# CIDR PLAN — Watchtower uses 10.4x/10.5x so it never overlaps Conduct (10.1x/10.2x),
# which is required for the Conduct ⇄ Watchtower VPC peering:
#   watchtower prod us-west-2  10.40.0.0/16   <-- this file
#   watchtower prod us-east-2  10.41.0.0/16
#   watchtower dev  us-west-2  10.50.0.0/16
locals {
  aws_region = "us-west-2"
  azs        = ["us-west-2a", "us-west-2b", "us-west-2c"]
  vpc_cidr   = "10.40.0.0/16"
}
