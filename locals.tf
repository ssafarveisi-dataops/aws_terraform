locals {
  models = yamldecode(file("${path.module}/models.yaml"))
  model_id = {
    for k, v in local.models : k => replace(k, "_", "-")
  }
}
