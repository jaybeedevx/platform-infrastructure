resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.1"
  wait       = true
  timeout    = 300 # seconds, adjust as needed

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.lb_controller_irsa_role_arn
  }

  set {
    name  = "replicaCount"
    value = "1"
  }
}

resource "helm_release" "aws_ebs_csi_driver" {
  name       = "aws-ebs-csi-driver"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  version    = "2.62.0"

  set {
    name  = "controller.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "controller.serviceAccount.name"
    value = "ebs-csi-controller-sa"
  }

  set {
    name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.ebs_csi_irsa_role_arn
  }

  set {
    name  = "controller.replicaCount"
    value = "1"
  }

  depends_on = [helm_release.aws_load_balancer_controller]
}

resource "helm_release" "aws_efs_csi_driver" {
  name       = "aws-efs-csi-driver"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/aws-efs-csi-driver"
  chart      = "aws-efs-csi-driver"
  version    = "2.5.0"

  set {
    name  = "controller.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "controller.serviceAccount.name"
    value = "efs-csi-controller-sa"
  }

  set {
    name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.efs_csi_irsa_role_arn
  }

  set {
    name  = "replicaCount"
    value = "1"
  }

  depends_on = [helm_release.aws_load_balancer_controller]
}

# 1. Metrics Server
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  chart      = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  version    = "3.12.0"

  depends_on = [helm_release.aws_load_balancer_controller]
}

# 2. Cert-Manager
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  chart            = "cert-manager"
  repository       = "https://charts.jetstack.io"
  version          = "1.14.0"
  set {
    name  = "installCRDs"
    value = "true"
  }

  # The AWS Load Balancer Controller registers a mutating webhook that
  # intercepts every Service create/update. cert-manager creates Services
  # (its webhook + main service), so it must install only after the
  # controller's webhook is serving -- otherwise Service creation is rejected
  # with "no endpoints available for service aws-load-balancer-webhook-service".
  depends_on = [helm_release.aws_load_balancer_controller]
}

# 3. External Secrets Operator (with IRSA)
# Use the OIDC provider from your `iam` module
data "aws_iam_policy_document" "external_secrets_read" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_secrets_read" {
  name   = "external-secrets-read"
  policy = data.aws_iam_policy_document.external_secrets_read.json
}

module "irsa_eso" {
  source = "../../modules/iam/irsa-role"

  name                 = "external-secrets-sa"
  oidc_provider_arn    = var.oidc_provider_arn
  issuer_url           = var.oidc_provider_url
  namespace            = "external-secrets"
  service_account_name = "external-secrets"
  policy_arns          = [aws_iam_policy.external_secrets_read.arn]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  chart            = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  version          = "0.9.11"
  depends_on       = [helm_release.aws_load_balancer_controller]

  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_eso.role_arn
  }
}

# 4. Argo CD
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "10.2.1"

  depends_on = [helm_release.aws_load_balancer_controller]


  values = [yamlencode({

    global = {
      image = {
        tag = "v3.4.5" # specify desired version
      }
    }
    # Admin user is enabled by default; we DO NOT disable it
    configs = {
      secret = {
        createSecret = true # Generate a random admin password
      }
    }
    controller = {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.argocd_irsa_role_arn
        }
      }
    }
    server = {
      service = {
        type = "LoadBalancer" # Required for NLB
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"
          "service.beta.kubernetes.io/aws-load-balancer-type"     = "nlb"
        }
      }
      # adminUser section removed – admin is enabled by default
    }
  })]
}