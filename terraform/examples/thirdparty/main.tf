terraform {
  required_version = "= 1.6.0"
}

module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace = "rxvgroup"
  name      = "thirdparty"
}

output "id" {
  value = module.label.id
}
