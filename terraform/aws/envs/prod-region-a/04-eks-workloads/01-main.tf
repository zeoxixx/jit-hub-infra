terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

data "aws_eks_cluster" "cluster" {
  name = "hello-eks"
}

data "aws_eks_cluster_auth" "cluster" {
  name = "hello-eks"
}

# KEDA 설치
module "keda" {
  source = "../../../modules/keda"

  release_name = "keda"
  namespace    = "keda"
}
