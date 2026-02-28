resource "aws_ecr_repository" "poc-ecr-repository" {
  name                 = "poc-deployment"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}
