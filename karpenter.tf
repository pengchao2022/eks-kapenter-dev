# 等待所有前置资源就绪
resource "time_sleep" "wait_for_prerequisites" {
  depends_on = [
    module.eks,
    aws_iam_role.karpenter_controller,
    aws_iam_instance_profile.karpenter,
    aws_ec2_tag.private_subnet_tags,
    aws_ec2_tag.vpc_tag,
    aws_ec2_tag.cluster_security_group_tag,
    aws_ec2_tag.node_security_group_tag
  ]

  create_duration = "3m"
}

# 使用 local-exec 安装 Karpenter
resource "null_resource" "install_karpenter" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = var.region
    karpenter_version = var.karpenter_version
  }

  provisioner "local-exec" {
    command = <<EOT
      # 更新 kubeconfig
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.region}

      # 创建 karpenter namespace
      kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -

      # 添加 Karpenter Helm 仓库
      helm repo add karpenter https://charts.karpenter.sh
      helm repo update

      # 安装 Karpenter
      helm upgrade --install karpenter karpenter/karpenter \
        --version ${var.karpenter_version} \
        --namespace karpenter \
        --set serviceAccount.annotations."eks\\.amazonaws\\.com/role-arn"=${aws_iam_role.karpenter_controller.arn} \
        --set clusterName=${module.eks.cluster_id} \
        --set clusterEndpoint=${module.eks.cluster_endpoint} \
        --set aws.defaultInstanceProfile=${aws_iam_instance_profile.karpenter.name} \
        --wait --timeout 300s
    EOT
  }

  depends_on = [time_sleep.wait_for_prerequisites]
}

# 等待 Karpenter 安装完成
resource "time_sleep" "wait_for_karpenter" {
  depends_on = [null_resource.install_karpenter]

  create_duration = "1m"
}

# 配置 Karpenter Provisioner 和 NodeTemplate
resource "null_resource" "configure_karpenter" {
  triggers = {
    karpenter_installed = null_resource.install_karpenter.id
  }

  provisioner "local-exec" {
    command = <<EOT
      # 更新 kubeconfig
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.region}

      # 创建 Provisioner
      cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
    - key: kubernetes.io/arch
      operator: In
      values: ["amd64"]
    - key: kubernetes.io/os
      operator: In
      values: ["linux"]
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["on-demand"]
    - key: node.kubernetes.io/instance-type
      operator: In
      values: ["t3.micro"]
  providerRef:
    name: default
  ttlSecondsAfterEmpty: 60
  limits:
    resources:
      cpu: 1000
  labels:
    node.kubernetes.io/instance-type: t3.micro
    environment: ${var.environment}
EOF

      # 创建 AWSNodeTemplate
      cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: default
spec:
  subnetSelector:
    karpenter.sh/discovery: ${var.cluster_name}
  securityGroupSelector:
    karpenter.sh/discovery: ${var.cluster_name}
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 20
        volumeType: gp3
        deleteOnTermination: true
        encrypted: true
  amiFamily: Ubuntu
  tags:
    karpenter.sh/discovery: ${var.cluster_name}
    Environment: ${var.environment}
    Terraform: "true"
    Project: "eks-karpenter"
EOF

      # 创建测试 Deployment
      cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
  namespace: default
spec:
  replicas: ${var.node_count}
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: "1"
EOF
    EOT
  }

  depends_on = [time_sleep.wait_for_karpenter]
}

# 手动安装 CoreDNS（避免 EKS addon 问题）
resource "null_resource" "install_coredns" {
  provisioner "local-exec" {
    command = <<EOT
      # 更新 kubeconfig
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.region}

      # 安装 CoreDNS
      kubectl apply -f https://raw.githubusercontent.com/aws/eks-charts/master/stable/coredns/coredns.yaml
    EOT
  }

  depends_on = [time_sleep.wait_for_prerequisites]
}