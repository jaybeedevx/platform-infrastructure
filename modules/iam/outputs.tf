output "ebs_csi_irsa_role_arn" {
  value = module.ebs_csi_irsa.role_arn
}

output "efs_csi_irsa_role_arn" {
  value = module.efs_csi_irsa.role_arn
}

output "lb_controller_irsa_role_arn" {
  value = module.lb_controller_irsa.role_arn
}
