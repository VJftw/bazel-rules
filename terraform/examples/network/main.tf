terraform {
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "3.6.0"
    }
  }
}

variable "name" {
  type    = string
  default = "network"
}

module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace = "network"
  name      = var.name
}

resource "random_pet" "this" {
  prefix = module.label.id
}

output "name" {
  value = random_pet.this.id
}
