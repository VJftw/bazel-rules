terraform {
  required_version = "= 1.4.0"
}

module "network" {
  source = "../network"
  name   = "legacy"
}
