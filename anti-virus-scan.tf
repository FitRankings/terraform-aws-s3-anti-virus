#
# Lambda Function: Anti-Virus Scanning
#

#
# IAM
#

data "aws_ssm_parameter" "datadog_api_key" {
  count = var.dd_parameter == "" ? 0 : 1
  name  = var.dd_parameter
}

data "aws_iam_policy_document" "assume_role_scan" {
  statement {
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "main_scan" {
  # Allow creating and writing CloudWatch logs for Lambda function.
  statement {
    sid = "WriteCloudWatchLogs"

    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_scan}:*"]
  }

  statement {
    sid = "s3AntiVirusScan"

    effect = "Allow"

    actions = concat([
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:PutObjectTagging",
      "s3:PutObjectVersionTagging",
    ], var.av_delete_infected_files == "True" ? ["s3:DeleteObject"] : [])

    resources = formatlist("%s/*", [for b in data.aws_s3_bucket.main_scan : b.arn])
  }

  statement {
    sid = "s3AntiVirusDefinitions"

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
    ]

    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.av_definition_s3_bucket}/${var.av_definition_s3_prefix}/*"]
  }

  statement {
    sid = "s3HeadObject"

    effect = "Allow"

    actions = [
      "s3:ListBucket",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.av_definition_s3_bucket}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.av_definition_s3_bucket}/*",
    ]
  }

  statement {
    sid = "kmsDecrypt"

    effect = "Allow"

    actions = [
      "kms:Decrypt",
    ]

    resources = formatlist("%s/*", [for b in data.aws_s3_bucket.main_scan : b.arn])
  }

  dynamic "statement" {
    for_each = length(compact([var.av_scan_start_sns_arn, var.av_status_sns_arn])) != 0 ? toset([0]) : toset([])

    content {
      sid = "snsPublish"

      actions = [
        "sns:Publish",
      ]

      resources = compact([var.av_scan_start_sns_arn, var.av_status_sns_arn])
    }
  }
}

resource "aws_iam_role" "main_scan" {
  name                 = "lambda-${var.name_scan}"
  assume_role_policy   = data.aws_iam_policy_document.assume_role_scan.json
  permissions_boundary = var.permissions_boundary
  tags                 = var.tags
}

resource "aws_iam_role_policy" "main_scan" {
  name = "lambda-${var.name_scan}"
  role = aws_iam_role.main_scan.id

  policy = data.aws_iam_policy_document.main_scan.json
}

#
# S3 Event
#

data "aws_s3_bucket" "main_scan" {
  for_each = { for bucket in var.av_scan_buckets : "${bucket.bucket}" => bucket }

  bucket = each.value.bucket
}

resource "aws_s3_bucket_notification" "main_scan" {
  for_each = { for bucket in var.av_scan_buckets : "${bucket.bucket}" => bucket }

  bucket = each.value.bucket

  dynamic "lambda_function" {
    for_each = toset(each.value.suffix != null ? each.value.suffix : [])
    content {
      id                  = replace("${data.aws_s3_bucket.main_scan[each.value.bucket].id}-suffix-${lambda_function.value}", "*", "all")
      lambda_function_arn = aws_lambda_function.main_scan.arn
      events              = ["s3:ObjectCreated:*"]
      filter_suffix       = lambda_function.value == "*" ? null : lambda_function.value
    }
  }

  dynamic "lambda_function" {
    for_each = toset(each.value.prefix != null ? each.value.prefix : [])
    content {
      id                  = "${data.aws_s3_bucket.main_scan[each.value.bucket].id}-prefix-${lambda_function.value}"
      lambda_function_arn = aws_lambda_function.main_scan.arn
      events              = ["s3:ObjectCreated:*"]
      filter_prefix       = lambda_function.value == "*" ? null : lambda_function.value
    }
  }
}

#
# CloudWatch Logs
#

resource "aws_cloudwatch_log_group" "main_scan" {
  # This name must match the lambda function name and should not be changed
  name              = "/aws/lambda/${var.name_scan}"
  retention_in_days = var.cloudwatch_logs_retention_days
  kms_key_id        = var.cloudwatch_kms_arn

  tags = merge(
    {
      "Name" = var.name_scan
    },
    var.tags
  )
}

#
# Lambda Function
#

resource "aws_lambda_function" "main_scan" {
  depends_on = [aws_cloudwatch_log_group.main_scan]

  description = "Scans s3 objects with clamav for viruses."

  s3_bucket = var.lambda_s3_bucket
  s3_key    = local.lambda_package_key

  function_name = var.name_scan
  role          = aws_iam_role.main_scan.arn
  handler       = "scan.lambda_handler"
  runtime       = "python3.7"
  memory_size   = var.memory_size
  timeout       = var.timeout_seconds

  environment {
    variables = {
      AV_DEFINITION_S3_BUCKET        = var.av_definition_s3_bucket
      AV_DEFINITION_S3_PREFIX        = var.av_definition_s3_prefix
      AV_SCAN_START_SNS_ARN          = var.av_scan_start_sns_arn
      AV_STATUS_SNS_ARN              = var.av_status_sns_arn
      AV_STATUS_SNS_PUBLISH_CLEAN    = var.av_status_sns_publish_clean
      AV_STATUS_SNS_PUBLISH_INFECTED = var.av_status_sns_publish_infected
      AV_DELETE_INFECTED_FILES       = var.av_delete_infected_files
      DATADOG_API_KEY                = var.dd_parameter == "" ? "" : data.aws_ssm_parameter.datadog_api_key[0].value
    }
  }

  tags = merge(
    {
      "Name" = var.name_scan
    },
    var.tags
  )
}

resource "aws_lambda_permission" "main_scan" {
  for_each = { for bucket in var.av_scan_buckets : bucket.bucket => bucket }

  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main_scan.function_name

  principal = "s3.amazonaws.com"

  source_account = data.aws_caller_identity.current.account_id
  source_arn     = data.aws_s3_bucket.main_scan[each.value.bucket].arn
  statement_id   = replace("${var.name_scan}-${data.aws_s3_bucket.main_scan[each.value.bucket].id}", ".", "-")
}
