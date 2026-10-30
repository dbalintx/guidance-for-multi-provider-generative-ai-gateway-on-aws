# ECS Fargate: cluster, the service task definition built ONLY from the
# container.tf locals, the one-off migration task definition, the migration gate
# and CPU+memory target-tracking auto scaling.

resource "aws_ecs_cluster" "this" {
  name = "${var.deployment_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

locals {
  # The ECS shape of local.container (container.tf) — nothing is defined here,
  # only converted. No entryPoint/command override: the image's entrypoint execs
  # `litellm --port 4000`, so the stop signal reaches LiteLLM directly.
  litellm_container = {
    name         = "LiteLLMContainer"
    image        = local.container.image
    essential    = true
    stopTimeout  = local.container.stop_timeout
    environment  = [for k, v in local.container.environment : { name = k, value = v }]
    secrets      = [for k, v in local.container.secrets : { name = k, valueFrom = v }]
    portMappings = [{ containerPort = local.container.port, protocol = "tcp" }]
    healthCheck = {
      command     = local.container.health_check_command
      interval    = 30
      timeout     = 10
      retries     = 3
      startPeriod = 60
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.litellm.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "LiteLLM"
      }
    }
  }

  # The tasks join the foundation's data-ingress group for RDS and Redis access.
  task_security_group_ids = concat(
    [aws_security_group.ecs_service.id],
    var.data_ingress_security_group_id != null ? [var.data_ingress_security_group_id] : [],
  )
}

resource "aws_ecs_task_definition" "litellm" {
  family                   = "${var.deployment_name}-litellm"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.vcpus * 1024
  memory                   = var.vcpus * 1024 * 2
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.architecture == "x86" ? "X86_64" : "ARM64"
  }

  container_definitions = jsonencode([local.litellm_container])
}

# One-off migration task: same image, schema updates on, `--skip_server_startup`
# migrates and exits. Service tasks keep DISABLE_SCHEMA_UPDATE=true.
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.deployment_name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.architecture == "x86" ? "X86_64" : "ARM64"
  }

  container_definitions = jsonencode([merge(
    { for k, v in local.litellm_container : k => v if !contains(["healthCheck", "portMappings", "stopTimeout"], k) },
    {
      name        = "Migrate"
      command     = ["--port", tostring(local.container.port), "--skip_server_startup"]
      environment = [for k, v in merge(local.container.environment, { DISABLE_SCHEMA_UPDATE = "false" }) : { name = k, value = v }]
    },
  )])
}

# Gate the rollout on the migration's exit code: LiteLLM's health endpoints
# report healthy on an unmigrated database (verified on 1.82.3 and 1.106.0), so
# neither the circuit breaker nor the ALB health check would catch a missed
# migration. deploy/run-migration.sh starts the task and waits for exit 0; the
# service (depends_on) only rolls after it.
resource "terraform_data" "migrate" {
  count            = var.run_migrations_on_apply ? 1 : 0
  triggers_replace = [aws_ecs_task_definition.migrate.revision, local.container.image]

  provisioner "local-exec" {
    command = "${path.module}/../../deploy/run-migration.sh"
    environment = {
      CLUSTER         = aws_ecs_cluster.this.name
      TASK_DEFINITION = aws_ecs_task_definition.migrate.arn
      SUBNETS         = join(",", var.private_subnet_ids)
      SECURITY_GROUPS = join(",", local.task_security_group_ids)
      AWS_REGION      = data.aws_region.current.region
    }
  }
}

resource "aws_ecs_service" "litellm" {
  name                              = "${var.deployment_name}-litellm"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.litellm.arn
  desired_count                     = var.desired_capacity
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 120

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = local.task_security_group_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.litellm.arn
    container_name   = "LiteLLMContainer"
    container_port   = local.container.port
  }

  deployment_controller {
    type = "ECS"
  }

  # Auto scaling owns the task count after creation: redeploys never reset it.
  lifecycle {
    ignore_changes = [desired_count]
  }

  # The target group must be attached to a listener, and the schema migrated,
  # before tasks roll.
  depends_on = [aws_lb_listener.http, aws_lb_listener.https, terraform_data.migrate]
}

resource "aws_appautoscaling_target" "litellm" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.litellm.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.deployment_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.litellm.resource_id
  scalable_dimension = aws_appautoscaling_target.litellm.scalable_dimension
  service_namespace  = aws_appautoscaling_target.litellm.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = var.cpu_target_utilization_percent
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 120
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.deployment_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.litellm.resource_id
  scalable_dimension = aws_appautoscaling_target.litellm.scalable_dimension
  service_namespace  = aws_appautoscaling_target.litellm.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = var.memory_target_utilization_percent
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
