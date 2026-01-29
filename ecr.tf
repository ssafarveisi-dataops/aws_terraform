resource "aws_ecr_repository" "poc-ecr-repository" {
  name                 = "dataops-poc-deployment"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}
