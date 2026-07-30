# Private ECR repos — one per app image. Immutable tags (build once, promote by
# digest), scan-on-push, and a lifecycle policy that expires all but the newest N
# images so the registry doesn't grow unbounded.
resource "aws_ecr_repository" "app" {
  for_each = toset(var.ecr_repositories)

  name                 = each.value
  image_tag_mutability = var.ecr_image_tag_mutability
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the ${var.ecr_keep_last_images} most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
