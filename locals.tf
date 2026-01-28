locals {
  models = yamldecode(file("${path.module}/models.yaml"))
}
