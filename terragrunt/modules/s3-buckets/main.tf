# ============================================================================
# s3-buckets — object storage backends for Loki (chunks) and Tempo (traces)
# ============================================================================
# Running Loki/Tempo against S3 is the cloud-native pattern: the tasks stay
# stateless and storage is durable + cheap. Each gets its own bucket. A
# lifecycle rule expires old data so retention is bounded.

variable "name_prefix" { type = string } # e.g. "watchtower-prod-us-west-2"
variable "buckets" {
  type    = list(string)
  default = ["loki", "tempo"]
}
variable "retention_days" {
  type    = number
  default = 30
}

resource "aws_s3_bucket" "this" {
  for_each = toset(var.buckets)
  bucket   = "${var.name_prefix}-${each.value}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    id     = "expire-old"
    status = "Enabled"
    filter {}
    expiration { days = var.retention_days }
  }
}

output "bucket_names" {
  value = { for k, b in aws_s3_bucket.this : k => b.id }
}
output "bucket_arns" {
  value = { for k, b in aws_s3_bucket.this : k => b.arn }
}
