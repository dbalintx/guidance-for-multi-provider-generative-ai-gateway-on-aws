# Bring-your-own VPC: validate it at plan time, before anything is created
# Hard problems fail the plan (preconditions); soft ones are
# warnings (checks). Nothing here assumes what the client of the data stores
# is — the IP arithmetic speaks of gateway replicas, not ECS tasks.

locals {
  byo_vpc            = !local.creating_new_vpc
  byo_subnet_ids     = local.byo_vpc ? toset(concat(var.private_subnet_ids, var.public_subnet_ids)) : toset([])
  required_endpoints = ["secretsmanager", "ecr.api", "ecr.dkr", "logs", "sts", "bedrock-runtime"]
}

data "aws_subnet" "byo" {
  for_each = local.byo_subnet_ids
  id       = each.value
}

# A subnet without an explicit route table association uses the VPC's main route table.
data "aws_route_tables" "byo_explicit" {
  for_each = local.byo_subnet_ids
  vpc_id   = var.vpc_id

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

data "aws_route_table" "byo_main" {
  count  = local.byo_vpc ? 1 : 0
  vpc_id = var.vpc_id

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

data "aws_route_table" "byo" {
  for_each       = local.byo_subnet_ids
  route_table_id = length(data.aws_route_tables.byo_explicit[each.value].ids) > 0 ? data.aws_route_tables.byo_explicit[each.value].ids[0] : data.aws_route_table.byo_main[0].id
}

locals {
  byo_igw_default_route = {
    for id, rt in data.aws_route_table.byo : id => anytrue([
      for r in rt.routes : r.cidr_block == "0.0.0.0/0" && startswith(coalesce(r.gateway_id, "-"), "igw-")
    ])
  }
  byo_nat_default_route = {
    for id, rt in data.aws_route_table.byo : id => anytrue([
      for r in rt.routes : r.cidr_block == "0.0.0.0/0" && (try(length(r.nat_gateway_id) > 0, false) || try(length(r.transit_gateway_id) > 0, false) || try(length(r.network_interface_id) > 0, false))
    ])
  }

  byo_foreign_subnets = [for id, s in data.aws_subnet.byo : id if s.vpc_id != var.vpc_id]
  byo_private_azs     = distinct([for id in var.private_subnet_ids : try(data.aws_subnet.byo[id].availability_zone, id)])
  byo_public_azs      = distinct([for id in var.public_subnet_ids : try(data.aws_subnet.byo[id].availability_zone, id)])
  byo_not_private     = [for id in var.private_subnet_ids : id if try(data.aws_subnet.byo[id].map_public_ip_on_launch, false) || try(local.byo_igw_default_route[id], false)]
  byo_public_no_igw   = [for id in var.public_subnet_ids : id if !try(local.byo_igw_default_route[id], false)]
  byo_free_ips        = sum(concat([0], [for id in var.private_subnet_ids : try(data.aws_subnet.byo[id].available_ip_address_count, 0)]))
  byo_entry_subnets   = var.public_mode ? length(var.public_subnet_ids) : length(var.private_subnet_ids)
  # Rolling deploys run up to 2x the gateway replicas; the entry point needs about
  # 8 free IPs per subnet; plus one endpoint ENI per service and subnet, RDS
  # (2 for Multi-AZ) and the Redis nodes.
  byo_ips_needed = var.max_gateway_instances * 2 + 8 * local.byo_entry_subnets + length(local.required_endpoints) * length(var.private_subnet_ids) + 2 + var.redis_num_cache_clusters
  byo_has_egress = anytrue([for id in var.private_subnet_ids : try(local.byo_nat_default_route[id], false)])
  byo_vpc_dns_ok = !local.byo_vpc || (try(data.aws_vpc.existing[0].enable_dns_support, false) && try(data.aws_vpc.existing[0].enable_dns_hostnames, false))
}

resource "terraform_data" "vpc_validation" {
  count = local.byo_vpc ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(var.private_subnet_ids) >= 2
      error_message = "With an existing vpc_id, set private_subnet_ids to at least two private subnets in different Availability Zones."
    }
    precondition {
      condition     = length(local.byo_foreign_subnets) == 0
      error_message = "These subnets are not in ${var.vpc_id}: ${join(", ", local.byo_foreign_subnets)}."
    }
    precondition {
      condition     = length(local.byo_private_azs) >= 2
      error_message = "private_subnet_ids must span at least 2 Availability Zones (found: ${join(", ", local.byo_private_azs)})."
    }
    precondition {
      condition     = length(local.byo_not_private) == 0
      error_message = "These private_subnet_ids are not private (internet gateway default route or public IPs on launch): ${join(", ", local.byo_not_private)}."
    }
    precondition {
      condition     = !var.public_mode || (length(local.byo_public_azs) >= 2 && length(local.byo_public_no_igw) == 0)
      error_message = "Public mode needs public_subnet_ids in at least 2 Availability Zones, each with an internet gateway default route. Without one: ${join(", ", local.byo_public_no_igw)}."
    }
    precondition {
      condition     = local.byo_free_ips >= local.byo_ips_needed
      error_message = "The private subnets have ${local.byo_free_ips} free IP addresses; this deployment needs about ${local.byo_ips_needed} (max gateway replicas x 2 for rolling deploys, the entry point, endpoints, RDS, Redis)."
    }
    precondition {
      condition     = var.public_mode || local.byo_vpc_dns_ok
      error_message = "Private mode needs DNS support and DNS hostnames enabled on the VPC (for private DNS on the VPC endpoints)."
    }
  }
}

# Warnings only: the plan continues.
check "byo_vpc_ip_headroom" {
  assert {
    condition     = !local.byo_vpc || local.byo_free_ips >= 2 * local.byo_ips_needed
    error_message = "Low IP headroom in the private subnets (${local.byo_free_ips} free, about ${local.byo_ips_needed} needed). Scaling or a second deployment may run out of addresses."
  }
}

check "byo_vpc_egress" {
  assert {
    condition     = !local.byo_vpc || local.byo_has_egress || var.egress_proxy_configured || var.disable_outbound_network_access
    error_message = "No NAT/TGW default route on the private subnets and no HTTPS proxy: the online licence check, the IdP (SSO/JWT) and non-Bedrock providers will not be reachable. Bedrock works through VPC endpoints."
  }
}

check "byo_vpc_endpoints" {
  # Check-scoped data source: a missing endpoint becomes a warning, not an error.
  data "aws_vpc_endpoint" "required" {
    vpc_id       = local.byo_vpc ? var.vpc_id : "vpc-unused"
    service_name = "com.amazonaws.${data.aws_region.current.region}.secretsmanager"
  }

  assert {
    condition     = !local.byo_vpc || local.create_endpoints || data.aws_vpc_endpoint.required.id != ""
    error_message = "No Secrets Manager endpoint in the existing VPC and create_vpc_endpoints_in_existing_vpc = false. Private gateway replicas need endpoints for: ${join(", ", local.required_endpoints)} and the S3 gateway endpoint."
  }
}
