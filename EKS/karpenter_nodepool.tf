# =========================
# Karpenter NodePool (default)
# =========================
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
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
              values: ["spot", "on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m", "r"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["2"]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          expireAfter: 720h
      limits:
        cpu: 1000
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [helm_release.karpenter]
}

# =========================
# Karpenter EC2NodeClass (default)
# =========================
resource "kubectl_manifest" "karpenter_ec2_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      role: "KarpenterNodeRole-${var.cluster_name}"
      amiSelectorTerms:
        - alias: "al2023@latest"
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      tags:
        karpenter.sh/discovery: "${var.cluster_name}"
  YAML

  depends_on = [helm_release.karpenter]
}
