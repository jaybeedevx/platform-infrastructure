output "release_names" {
  value = [
    helm_release.aws_load_balancer_controller.name,
    helm_release.aws_ebs_csi_driver.name,
    helm_release.aws_efs_csi_driver.name,
  ]
}
