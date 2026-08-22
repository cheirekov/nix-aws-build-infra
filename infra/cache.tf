locals {
  cache_bucket_name = "${var.project_name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  parameter_prefix  = "/${var.project_name}"
}

resource "aws_s3_bucket" "cache" {
  bucket        = local.cache_bucket_name
  force_destroy = false

  tags = { Name = local.cache_bucket_name }
}

resource "aws_s3_bucket_public_access_block" "cache" {
  bucket = aws_s3_bucket.cache.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cache" {
  bucket = aws_s3_bucket.cache.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cache" {
  bucket = aws_s3_bucket.cache.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_cloudfront_origin_access_control" "cache" {
  name                              = "${var.project_name}-cache"
  description                       = "Private S3 access for the public Nix cache"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cache" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.project_name} signed Nix binary cache"
  price_class     = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.cache.bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.cache.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.cache.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${aws_s3_bucket.cache.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  custom_error_response {
    error_code            = 403
    error_caching_min_ttl = 1
  }

  custom_error_response {
    error_code            = 404
    error_caching_min_ttl = 1
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate { cloudfront_default_certificate = true }
}

data "aws_iam_policy_document" "cache_cloudfront" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.cache.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cache.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "cache" {
  bucket = aws_s3_bucket.cache.id
  policy = data.aws_iam_policy_document.cache_cloudfront.json
}

resource "aws_secretsmanager_secret" "cache_signing_key" {
  name                    = "${var.project_name}/cache-signing-key"
  description             = "Nix binary cache private signing key; value managed outside OpenTofu"
  recovery_window_in_days = 7
}

resource "aws_ssm_parameter" "cache_url" {
  name  = "${local.parameter_prefix}/config/cache-url"
  type  = "String"
  value = "https://${aws_cloudfront_distribution.cache.domain_name}"
}

resource "aws_ssm_parameter" "cache_bucket" {
  name  = "${local.parameter_prefix}/config/cache-bucket"
  type  = "String"
  value = aws_s3_bucket.cache.id
}

resource "aws_ssm_parameter" "cache_public_key" {
  name  = "${local.parameter_prefix}/config/cache-public-key"
  type  = "String"
  value = var.cache_public_key
}

resource "aws_ssm_parameter" "provisioner_config" {
  name = "${local.parameter_prefix}/config/provisioner"
  type = "String"
  value = jsonencode({
    cache_bucket             = aws_s3_bucket.cache.id
    cache_signing_secret_arn = aws_secretsmanager_secret.cache_signing_key.arn
    cache_url                = "https://${aws_cloudfront_distribution.cache.domain_name}"
    instance_profile_name    = aws_iam_instance_profile.runner.name
    kms_key_id               = aws_kms_key.runner_config.arn
    root_volume_gb           = var.runner_root_volume_gb
    root_volume_iops         = var.runner_root_volume_iops
    root_volume_throughput   = var.runner_root_volume_throughput
    runner_security_group_id = aws_security_group.runner.id
    runner_subnet_ids        = aws_subnet.builder[*].id
  })
}

resource "aws_ssm_parameter" "builder_ami" {
  name        = "${local.parameter_prefix}/ami/current"
  description = "Current Packer-built ephemeral runner AMI"
  type        = "String"
  value       = "pending"

  lifecycle { ignore_changes = [value] }
}
