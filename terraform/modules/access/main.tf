# access — how operators and automation reach the private cluster.
#
# The control plane has no public endpoint, so the only way in is the fleet's
# Connect Gateway. Reaching the cluster takes two grants that must agree:
#   1. Google IAM — permission to use Connect Gateway and read the membership
#      (this module's resources).
#   2. Kubernetes RBAC — the identity (mapped by the gateway to its email) is
#      bound to a ClusterRole, or it can authenticate but do nothing (this
#      module's rendered manifest output, applied by the pipeline with kubectl).
# Both are derived from the same identity list so they can't drift apart.
# See docs/implementation/cluster-build.md for "how an operator connects".

locals {
  # Operators plus automation all need to traverse the gateway. Granted at the
  # project level (SRE operate every cluster in the project); tightening to a
  # per-membership grant is a future least-privilege step.
  gateway_members = concat(var.operator_members, [var.automation_member])

  # The gateway authenticates a Google identity and presents it to the cluster
  # as a Kubernetes user named by its email; only Google Groups map to Group.
  # RBAC binds the operators only — the automation is already cluster-admin via
  # the GKE IAM authorizer (it holds roles/container.admin), so binding it again
  # would be redundant.
  rbac_subjects = [
    for m in var.operator_members : {
      kind = startswith(m, "group:") ? "Group" : "User"
      name = regex("^[^:]+:(.*)$", m)[0]
    }
  ]
}

# --- Google side: Connect Gateway access ------------------------------------

# Use the gateway (generate credentials, proxy kubectl). Editor = read-write,
# which operators and the applying automation both need.
resource "google_project_iam_member" "gateway" {
  for_each = toset(local.gateway_members)
  project  = var.project_id
  role     = "roles/gkehub.gatewayEditor"
  member   = each.value
}

# Look up the fleet membership the gateway routes through. Without this the
# gateway role can't resolve which cluster to reach.
resource "google_project_iam_member" "fleet_viewer" {
  for_each = toset(local.gateway_members)
  project  = var.project_id
  role     = "roles/gkehub.viewer"
  member   = each.value
}
