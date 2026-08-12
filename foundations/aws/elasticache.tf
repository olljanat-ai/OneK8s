# Shared ElastiCache Serverless (Valkey) for the cluster — AWS's managed
# Redis-compatible offering. Consumed by tenants that opt in with
# `redis_enabled = true`: each tenant gets a password-authenticated
# ElastiCache user whose ACL is scoped to the "<tenant>:" key prefix,
# associated into the user group below; the password lands in Secrets
# Manager under the tenant's prefix and reaches the workload via ESO
# (see modules/tenant-namespace/aws and ADR-0002).
resource "aws_security_group" "redis" {
  name        = "redis-${local.name}"
  description = "ElastiCache serverless access for cluster workloads"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Valkey TLS (primary + reader endpoints) from within the VPC"
    from_port   = 6379
    to_port     = 6380
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "sg-redis-${local.name}" }
}

# RBAC requires a user named "default" in every user group; this one is
# disabled ("off" + no commands) so only tenant users can authenticate.
resource "aws_elasticache_user" "redis_default" {
  user_id       = "onek8s-${var.environment}-default"
  user_name     = "default"
  engine        = "valkey"
  access_string = "off ~* -@all"

  authentication_mode {
    type = "no-password-required"
  }
}

resource "aws_elasticache_user_group" "redis_tenants" {
  engine        = "valkey"
  user_group_id = "onek8s-${var.environment}-redis-tenants"
  user_ids      = [aws_elasticache_user.redis_default.user_id]

  # Tenant users are associated by the tenants stack via
  # aws_elasticache_user_group_association; don't fight over membership here.
  lifecycle {
    ignore_changes = [user_ids]
  }
}

resource "aws_elasticache_serverless_cache" "redis" {
  name        = "redis-${local.name}"
  description = "Shared tenant Redis (Valkey) for ${local.name}"
  engine      = "valkey"

  major_engine_version = "8"
  subnet_ids           = aws_subnet.private[*].id
  security_group_ids   = [aws_security_group.redis.id]
  user_group_id        = aws_elasticache_user_group.redis_tenants.user_group_id

  # Hard cost ceiling; serverless otherwise scales with usage.
  cache_usage_limits {
    data_storage {
      maximum = var.redis_max_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.redis_max_ecpu_per_second
    }
  }
}
