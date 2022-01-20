terraform {
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 4.4, <= 4.12.0"
    }
  }
  required_version = ">= 0.14"
}
