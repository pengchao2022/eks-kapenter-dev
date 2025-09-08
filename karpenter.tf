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
    cluster_name      = module.eks.cluster_name
    region            = var.region
    karpenter_version = var.karpenter_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      set -e

      # 更新 kubeconfig
      aws eks update-kubeconfig \
        --name "${module.eks.cluster_name}" \
        --region "${var.region}"

      # 等待集群端点可用
      echo "等待 EKS 集群端点就绪..."
      sleep 30

      # 创建 karpenter namespace
      kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -

      # 添加 Karpenter Helm 仓库
      helm repo add karpenter https://charts.karpenter.sh
      helm repo update

      # 获取 EKS 集群信息
      CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${module.eks.cluster_name}" --region "${var.region}" --query "cluster.endpoint" --output text)
      CLUSTER_ID=$(aws eks describe-cluster --name "${module.eks.cluster_name}" --region "${var.region}" --query "cluster.id" --output text)

      # 安装 Karpenter
      helm upgrade --install karpenter karpenter/karpenter \
        --version "${var.karpenter_version}" \
        --namespace karpenter \
        --set serviceAccount.annotations."eks\\.amazonaws\\.com/role-arn"="${aws_iam_role.karpenter_controller.arn}" \
        --set clusterName="${CLUSTER_ID}" \
        --set clusterEndpoint="${CLUSTER_ENDPOINT}" \
        --set aws.defaultInstanceProfile="${aws_iam_instance_profile.karpenter.name}" \
        --wait --timeout 300s

      echo "Karpenter 安装完成"
    EOT
  }

  depends_on = [time_sleep.wait_for_prerequisites]
}

# 等待 Karpenter 安装完成
resource "time_sleep" "wait_for_karpenter" {
  depends_on = [null_resource.install_karpenter]

  create_duration = "2m"
}

# 配置 Karpenter Provisioner 和 NodeTemplate
resource "null_resource" "configure_karpenter" {
  triggers = {
    karpenter_installed = null_resource.install_karpenter.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      set -e

      # 更新 kubeconfig
      aws eks update-kubeconfig \
        --name "${module.eks.cluster_name}" \
        --region "${var.region}"

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

      echo "Karpenter 配置完成"
    EOT
  }

  depends_on = [time_sleep.wait_for_karpenter]
}

# 手动安装 CoreDNS（使用正确的 URL）
resource "null_resource" "install_coredns" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      set -e

      # 更新 kubeconfig
      aws eks update-kubeconfig \
        --name "${module.eks.cluster_name}" \
        --region "${var.region}"

      # 等待集群端点可用
      echo "等待 EKS 集群端点就绪..."
      sleep 30

      # 安装 CoreDNS（使用正确的 manifest）
      kubectl apply -f https://raw.githubusercontent.com/aws/eks-charts/master/stable/coredns/coredns-1.9.3.yaml

      # 或者使用内联的 CoreDNS manifest
      cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coredns
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
rules:
- apiGroups:
  - ""
  resources:
  - endpoints
  - services
  - pods
  - namespaces
  verbs:
  - list
  - watch
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:coredns
subjects:
- kind: ServiceAccount
  name: coredns
  namespace: kube-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: coredns
      tolerations:
        - key: "CriticalAddonsOnly"
          operator: "Exists"
      nodeSelector:
        kubernetes.io/os: linux
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: k8s-app
                  operator: In
                  values: ["kube-dns"]
              topologyKey: kubernetes.io/hostname
      containers:
      - name: coredns
        image: public.ecr.aws/eks-distro/coredns/coredns:v1.9.3-eks-1-28-5
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        args: [ "-conf", "/etc/coredns/Corefile" ]
        volumeMounts:
        - name: config-volume
          mountPath: /etc/coredns
          readOnly: true
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        - containerPort: 9153
          name: metrics
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /ready
            port: 8181
            scheme: HTTP
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - all
          readOnlyRootFilesystem: true
      dnsPolicy: Default
      volumes:
        - name: config-volume
          configMap:
            name: coredns
            items:
            - key: Corefile
              path: Corefile
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  annotations:
    prometheus.io/port: "9153"
    prometheus.io/scrape: "true"
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "CoreDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 10.100.0.10
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
  - name: metrics
    port: 9153
    protocol: TCP
EOF

      echo "CoreDNS 安装完成"
    EOT
  }

  depends_on = [time_sleep.wait_for_prerequisites]
}