# Optional demo Client VPN (off by default): a way to reach a private gateway
# for trials, not a production access path. Associated with ONE private subnet —
# every association is billed hourly and one is enough to reach the whole VPC.
# The app admits the VPN by security group (vpn_security_group_id output), so
# nothing here knows about the ALB.

module "vpn" {
  source = "../modules/vpn"
  count  = var.create_vpn ? 1 : 0

  deployment_name             = var.deployment_name
  vpc_id                      = local.vpc_id
  vpc_cidr                    = local.vpc_cidr
  subnet_ids                  = slice(local.private_subnet_ids, 0, 1)
  server_certificate_arn      = var.vpn_server_certificate_arn
  client_root_certificate_arn = var.vpn_client_root_certificate_arn
  client_cidr                 = var.vpn_client_cidr
  egress_ports                = var.vpn_egress_ports
  log_retention_days          = var.log_retention_days
  kms_key_arn                 = var.kms_key_arn
}
