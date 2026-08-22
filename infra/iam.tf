resource "aws_kms_key" "runner_config" {
  description             = "Encrypt one-time runner registration parameters"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "runner_config" {
  name          = "alias/${var.project_name}-runner-config"
  target_key_id = aws_kms_key.runner_config.key_id
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for repository, repository_id in var.allowed_repositories :
        "repo:${var.github_owner}@${var.github_owner_id}/${repository}@${repository_id}:environment:${var.github_environment}"
      ]
    }
  }
}

resource "aws_iam_role" "github_provisioner" {
  name               = "${var.project_name}-github-provisioner"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

resource "aws_iam_role" "runner" {
  name = "${var.project_name}-runner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.project_name}-runner"
  role = aws_iam_role.runner.name
}

data "aws_iam_policy_document" "github_provisioner" {
  statement {
    sid = "ManageEphemeralFleet"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteFleets",
      "ec2:DeleteLaunchTemplate",
      "ec2:DescribeFleetInstances",
      "ec2:DescribeFleets",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeSpotPriceHistory",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassRunnerRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.runner.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid = "ManageOneTimeRunnerParameters"
    actions = [
      "ssm:DeleteParameter",
      "ssm:GetParameter",
      "ssm:PutParameter",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/runs/*"]
  }

  statement {
    sid     = "ReadBuilderConfiguration"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/ami/*",
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/config/*",
    ]
  }

  statement {
    sid       = "EncryptRunnerConfiguration"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.runner_config.arn]
  }
}

resource "aws_iam_role_policy" "github_provisioner" {
  name   = "${var.project_name}-provisioner"
  role   = aws_iam_role.github_provisioner.id
  policy = data.aws_iam_policy_document.github_provisioner.json
}

data "aws_iam_policy_document" "runner" {
  statement {
    sid       = "ReadRunConfiguration"
    actions   = ["ssm:GetParameter", "ssm:DeleteParameter"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/runs/*"]
  }

  statement {
    sid       = "DecryptRunConfiguration"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.runner_config.arn]
  }

  statement {
    sid       = "ReadCacheConfiguration"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/config/*"]
  }

  statement {
    sid       = "ReadSigningKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.cache_signing_key.arn]
  }

  statement {
    sid = "WriteBinaryCache"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.cache.arn}/*"]
  }

  statement {
    sid       = "InspectBinaryCache"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.cache.arn]
  }

  statement {
    sid = "PublishRunnerLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.runners.arn}:*"]
  }
}

resource "aws_iam_role_policy" "runner" {
  name   = "${var.project_name}-runner"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner.json
}

resource "aws_iam_role_policy_attachment" "runner_ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "github_image_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}@${var.github_owner_id}/nix-aws-build-infra@${var.allowed_repositories["nix-aws-build-infra"]}:environment:${var.github_environment}"]
    }
  }
}

resource "aws_iam_role" "github_image_builder" {
  name               = "${var.project_name}-github-image-builder"
  assume_role_policy = data.aws_iam_policy_document.github_image_assume.json
}

resource "aws_iam_role_policy" "github_image_builder" {
  name = "${var.project_name}-image-builder"
  role = aws_iam_role.github_image_builder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AttachVolume",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CopyImage",
          "ec2:CreateImage",
          "ec2:CreateKeyPair",
          "ec2:CreateSecurityGroup",
          "ec2:CreateSnapshot",
          "ec2:CreateTags",
          "ec2:CreateVolume",
          "ec2:DeleteKeyPair",
          "ec2:DeleteSecurityGroup",
          "ec2:DeleteSnapshot",
          "ec2:DeleteVolume",
          "ec2:DeregisterImage",
          "ec2:DescribeImageAttribute",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeRegions",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSnapshots",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVpcs",
          "ec2:DetachVolume",
          "ec2:GetPasswordData",
          "ec2:ModifyImageAttribute",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifySnapshotAttribute",
          "ec2:RegisterImage",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RunInstances",
          "ec2:StopInstances",
          "ec2:TerminateInstances",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = aws_ssm_parameter.builder_ami.arn
      },
    ]
  })
}
