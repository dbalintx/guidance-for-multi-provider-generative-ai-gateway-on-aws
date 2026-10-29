# Plan-time validation of a bring-your-own VPC, with a mocked AWS provider
# (no credentials, no AWS). Ports the ideation 2.7 fail and warn rules.
# Run: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-byo", cidr_block = "10.1.0.0/16", enable_dns_support = true, enable_dns_hostnames = true }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b"] }
  }
  mock_data "aws_route_tables" {
    defaults = { ids = [] }
  }
  mock_data "aws_route_table" {
    defaults = {
      id     = "rtb-main"
      routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "", nat_gateway_id = "nat-1", transit_gateway_id = "", network_interface_id = "" }]
    }
  }
  mock_data "aws_vpc_endpoint" {
    defaults = { id = "vpce-1" }
  }
}

mock_provider "random" {}

variables {
  deployment_name                      = "llmgw"
  vpc_id                               = "vpc-byo"
  private_subnet_ids                   = ["subnet-a", "subnet-b"]
  public_subnet_ids                    = []
  public_mode                          = false
  create_vpc_endpoints_in_existing_vpc = true
  max_gateway_instances                = 4
}

# Two private subnets in two AZs with a NAT route: valid.
override_data {
  target = data.aws_subnet.byo["subnet-a"]
  values = { id = "subnet-a", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = false, available_ip_address_count = 200 }
}
override_data {
  target = data.aws_subnet.byo["subnet-b"]
  values = { id = "subnet-b", vpc_id = "vpc-byo", availability_zone = "eu-west-1b", map_public_ip_on_launch = false, available_ip_address_count = 200 }
}

run "valid_private_vpc" {
  command = plan

  assert {
    condition     = length(terraform_data.vpc_validation) == 1
    error_message = "Validation should run for an existing VPC."
  }

  assert {
    condition     = length(aws_vpc.new) == 0 && length(aws_subnet.private) == 0
    error_message = "No VPC or subnets may be created when one is brought."
  }
}

run "new_vpc_skips_validation" {
  command = plan

  variables {
    vpc_id             = null
    private_subnet_ids = []
  }

  assert {
    condition     = length(terraform_data.vpc_validation) == 0
    error_message = "No validation expected when the module creates the VPC."
  }
}

run "subnet_in_other_vpc" {
  command = plan

  override_data {
    target = data.aws_subnet.byo["subnet-b"]
    values = { id = "subnet-b", vpc_id = "vpc-other", availability_zone = "eu-west-1b", map_public_ip_on_launch = false, available_ip_address_count = 200 }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "single_az" {
  command = plan

  override_data {
    target = data.aws_subnet.byo["subnet-b"]
    values = { id = "subnet-b", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = false, available_ip_address_count = 200 }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "private_subnet_with_public_ips" {
  command = plan

  override_data {
    target = data.aws_subnet.byo["subnet-a"]
    values = { id = "subnet-a", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = true, available_ip_address_count = 200 }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "private_subnet_routes_to_igw" {
  command = plan

  override_data {
    target = data.aws_route_table.byo["subnet-a"]
    values = { id = "rtb-pub", routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "igw-1", nat_gateway_id = "", transit_gateway_id = "", network_interface_id = "" }] }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "not_enough_free_ips" {
  command = plan

  variables {
    max_gateway_instances = 20
  }

  override_data {
    target = data.aws_subnet.byo["subnet-a"]
    values = { id = "subnet-a", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = false, available_ip_address_count = 10 }
  }

  override_data {
    target = data.aws_subnet.byo["subnet-b"]
    values = { id = "subnet-b", vpc_id = "vpc-byo", availability_zone = "eu-west-1b", map_public_ip_on_launch = false, available_ip_address_count = 10 }
  }

  expect_failures = [terraform_data.vpc_validation, check.byo_vpc_ip_headroom]
}

run "public_mode_without_public_subnets" {
  command = plan

  variables {
    public_mode = true
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "public_mode_with_public_subnets_in_two_azs" {
  command = plan

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-pa", "subnet-pb"]
  }

  override_data {
    target = data.aws_subnet.byo["subnet-pa"]
    values = { id = "subnet-pa", vpc_id = "vpc-byo", availability_zone = "eu-west-1a", map_public_ip_on_launch = true, available_ip_address_count = 200 }
  }

  override_data {
    target = data.aws_subnet.byo["subnet-pb"]
    values = { id = "subnet-pb", vpc_id = "vpc-byo", availability_zone = "eu-west-1b", map_public_ip_on_launch = true, available_ip_address_count = 200 }
  }

  override_data {
    target = data.aws_route_table.byo["subnet-pa"]
    values = { id = "rtb-pub", routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "igw-1", nat_gateway_id = "", transit_gateway_id = "", network_interface_id = "" }] }
  }

  override_data {
    target = data.aws_route_table.byo["subnet-pb"]
    values = { id = "rtb-pub", routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "igw-1", nat_gateway_id = "", transit_gateway_id = "", network_interface_id = "" }] }
  }

  assert {
    condition     = length(terraform_data.vpc_validation) == 1
    error_message = "Validation must pass for a correctly laid out public-mode VPC."
  }
}

run "private_mode_needs_vpc_dns" {
  command = plan

  override_data {
    target = data.aws_vpc.existing[0]
    values = { id = "vpc-byo", cidr_block = "10.1.0.0/16", enable_dns_support = true, enable_dns_hostnames = false }
  }

  expect_failures = [terraform_data.vpc_validation]
}

run "no_egress_is_a_warning_not_an_error" {
  command = plan

  override_data {
    target = data.aws_route_table.byo["subnet-a"]
    values = { id = "rtb-iso", routes = [] }
  }

  override_data {
    target = data.aws_route_table.byo["subnet-b"]
    values = { id = "rtb-iso", routes = [] }
  }

  expect_failures = [check.byo_vpc_egress]
}

run "egress_proxy_silences_the_egress_warning" {
  command = plan

  variables {
    egress_proxy_configured = true
  }

  override_data {
    target = data.aws_route_table.byo["subnet-a"]
    values = { id = "rtb-iso", routes = [] }
  }

  override_data {
    target = data.aws_route_table.byo["subnet-b"]
    values = { id = "rtb-iso", routes = [] }
  }
}

run "missing_endpoints_is_a_warning" {
  command = plan

  variables {
    create_vpc_endpoints_in_existing_vpc = false
  }

  override_data {
    target = data.aws_vpc_endpoint.required
    values = { id = "" }
  }

  expect_failures = [check.byo_vpc_endpoints]
}
