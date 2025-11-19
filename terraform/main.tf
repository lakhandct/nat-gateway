###############################################################################
# NAT HA on Linode – Single or Multi Pair (auto-detects from var.nat_pairs)
###############################################################################

# -----------------------------------------------------------------------------
# Cloud-init: install base tools + Ansible on first boot
# -----------------------------------------------------------------------------
locals {
  cloud_init = <<-EOF
  #cloud-config
  package_update: true
  packages:
    - ca-certificates
    - curl
    - jq
    - vim
    - python3
    - python3-pip
    - git
    - keepalived
    - nftables
    - conntrack
  runcmd:
    - pip3 install --upgrade pip
    - pip3 install ansible
    - systemctl enable keepalived || true
    - systemctl enable nftables || true
  %{if var.inject_ssh_via_cloud_init~}
  ssh_authorized_keys:
  %{for k in var.ssh_authorized_keys~}
    - ${k}
  %{endfor~}
  %{endif~}
  EOF
}

# -----------------------------------------------------------------------------
# Multi vs Single detection + normalized data
# -----------------------------------------------------------------------------
locals {
  # Always normalize nat_pairs (list(object)) -> map(name => object)
  nat_pairs_by_name = { for p in var.nat_pairs : p.name => p }

  # Canonical mode flags
  pair_names = keys(local.nat_pairs_by_name)
  is_multi   = length(local.pair_names) > 0
  multi      = local.is_multi # back-compat for any existing local.multi refs

  # Flatten members for for_each in multi mode
  members_flat = flatten([
    for pname, p in local.nat_pairs_by_name : [
      for m in p.members : {
        pair_name   = pname
        vlan_label  = p.vlan_label
        vlan_vip    = p.vlan_vip
        shared_ipv4 = try(p.shared_ipv4, "")
        vrrp_id     = p.vrrp_id
        label       = m.label
        vlan_ip     = m.vlan_ip
        state       = m.state
        priority    = m.priority
      }
    ]
  ])

  members_by_label = { for m in local.members_flat : m.label => m }

  # Peer IP for each node (trim /24)
  peer_ip_by_label = merge([
    for pname, p in local.nat_pairs_by_name : {
      for m in p.members :
      m.label => trimsuffix(
        element([for x in p.members : x.vlan_ip if x.label != m.label], 0),
        "/24"
      )
    }
  ]...)

  # Local IP per node (trim /24)
  local_ip_by_label = {
    for m in local.members_flat : m.label => trimsuffix(m.vlan_ip, "/24")
  }
}

# -----------------------------------------------------------------------------
# SINGLE-PAIR MODE INSTANCES
# -----------------------------------------------------------------------------
resource "linode_instance" "nat_a" {
  count           = local.is_multi ? 0 : 1
  label           = "${var.prefix}-a"
  region          = var.region
  image           = var.image
  type            = var.type
  root_pass       = var.root_pass != "" ? var.root_pass : null
  authorized_keys = var.inject_ssh_via_cloud_init ? null : var.ssh_authorized_keys

  interface { purpose = "public" }
  interface {
    purpose      = "vlan"
    label        = var.vlan_label
    ipam_address = "${var.nat_a_vlan_ip}/24"
  }

  tags = ["nat", "gateway", "ha", "primary"]
  metadata { user_data = base64encode(local.cloud_init) }
}

resource "linode_instance" "nat_b" {
  count           = local.is_multi ? 0 : 1
  label           = "${var.prefix}-b"
  region          = var.region
  image           = var.image
  type            = var.type
  root_pass       = var.root_pass != "" ? var.root_pass : null
  authorized_keys = var.inject_ssh_via_cloud_init ? null : var.ssh_authorized_keys

  interface { purpose = "public" }
  interface {
    purpose      = "vlan"
    label        = var.vlan_label
    ipam_address = "${var.nat_b_vlan_ip}/24"
  }

  tags = ["nat", "gateway", "ha", "backup"]
  metadata { user_data = base64encode(local.cloud_init) }
}

# -----------------------------------------------------------------------------
# MULTI-PAIR MODE INSTANCES
# -----------------------------------------------------------------------------
resource "linode_instance" "multi" {
  for_each        = local.is_multi ? { for m in local.members_flat : m.label => m } : {}
  label           = each.value.label
  region          = var.region
  image           = var.image
  type            = var.type
  root_pass       = var.root_pass != "" ? var.root_pass : null
  authorized_keys = var.inject_ssh_via_cloud_init ? null : var.ssh_authorized_keys

  interface { purpose = "public" }
  interface {
    purpose      = "vlan"
    label        = each.value.vlan_label
    ipam_address = "${each.value.vlan_ip}/24"
  }

  tags = compact(["nat", "gateway", "ha", each.value.state == "MASTER" ? "primary" : "backup"])
  metadata { user_data = base64encode(local.cloud_init) }
}

# -----------------------------------------------------------------------------
# IP SHARING (single & multi)
# -----------------------------------------------------------------------------
resource "null_resource" "ip_share_nat_a" {
  count = local.is_multi ? 0 : (var.use_ip_share && length(var.shared_ipv4) > 0 ? 1 : 0)

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<-EOC
      set -euo pipefail
      echo "Sharing ${var.shared_ipv4} to nat-a (linode_id=${linode_instance.nat_a[0].id})"
      curl -sS -H "Authorization: Bearer ${var.linode_token}" \
           -H "Content-Type: application/json" \
           -X POST \
           -d '{"ips":["${var.shared_ipv4}"],"linode_id": ${linode_instance.nat_a[0].id}}' \
           https://api.linode.com/v4/networking/ips/share >/dev/null
      echo "Share to nat-a completed."
    EOC
  }

  depends_on = [linode_instance.nat_a]
}

resource "null_resource" "ip_share_nat_b" {
  count = local.is_multi ? 0 : (var.use_ip_share && length(var.shared_ipv4) > 0 ? 1 : 0)

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<-EOC
      set -euo pipefail
      echo "Sharing ${var.shared_ipv4} to nat-b (linode_id=${linode_instance.nat_b[0].id})"
      curl -sS -H "Authorization: Bearer ${var.linode_token}" \
           -H "Content-Type: application/json" \
           -X POST \
           -d '{"ips":["${var.shared_ipv4}"],"linode_id": ${linode_instance.nat_b[0].id}}' \
           https://api.linode.com/v4/networking/ips/share >/dev/null
      echo "Share to nat-b completed."
    EOC
  }

  depends_on = [linode_instance.nat_b]
}

resource "null_resource" "ip_share_multi" {
  for_each = local.is_multi && var.use_ip_share ? {
    for m in local.members_flat : m.label => m
    if length(trimspace(m.shared_ipv4)) > 0
  } : {}

  triggers = {
    shared_ipv4 = trimspace(each.value.shared_ipv4)
    linode_id   = linode_instance.multi[each.key].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<-EOC
      set -euo pipefail
      IP="${each.value.shared_ipv4}"
      NODE_ID=${linode_instance.multi[each.key].id}
      echo "⇒ Sharing $${IP} to ${each.key} (linode_id=$${NODE_ID})"
      for i in 1 2 3; do
        curl -sS -H "Authorization: Bearer ${var.linode_token}" \
             -H "Content-Type: application/json" \
             -X POST \
             -d '{"ips":["'"$${IP}"'"],"linode_id": '"$${NODE_ID}"'}' \
             https://api.linode.com/v4/networking/ips/share && break || {
          echo "   share attempt $i failed; retrying in $((i*2))s..."
          sleep $((i*2))
        }
      done
      echo "✓ Share to ${each.key} completed."
    EOC
  }

  depends_on = [linode_instance.multi]
}

# -----------------------------------------------------------------------------
# Files for Ansible (both modes)
# -----------------------------------------------------------------------------
resource "null_resource" "create_hostvars_dir" {
  count = 1
  provisioner "local-exec" { 
    interpreter = ["/bin/bash", "-lc"]
    command = "mkdir -p ../ansible/host_vars" 
  }
}

# Inventory (single)
resource "local_file" "ansible_inventory_single" {
  count    = local.is_multi ? 0 : 1
  filename = "${path.module}/../ansible/inventory.ini"
  content  = <<-EOT
[nat]
nat-a ansible_host=${tolist(linode_instance.nat_a[0].ipv4)[0]} state=MASTER priority=150
nat-b ansible_host=${tolist(linode_instance.nat_b[0].ipv4)[0]} state=BACKUP priority=100

[nat:vars]
ansible_user=root
pub_if=eth0
vlan_if=eth1
EOT

  depends_on = [
    linode_instance.nat_a,
    linode_instance.nat_b
  ]
}

# group_vars (single)
resource "local_file" "ansible_group_vars_single" {
  count    = local.is_multi ? 0 : 1
  filename = "${path.module}/../ansible/group_vars/nat.yml"

  content = <<-YAML
    # Auto-generated by Terraform. Do not edit by hand.
    fip: "${var.shared_ipv4}"
    vlan_vip: "${var.vlan_vip}"

    # VRRP parameters (single-pair)
    vrrp_id: ${var.vrrp_id}
    vrrp_instance: "VGW1"
    vrrp_interface: "eth1"
    vrrp_auth_pass: "nat-pass"

    # Interfaces (match what Terraform created on the Linodes)
    pub_if: "eth0"
    vlan_if: "eth1"
  YAML

  depends_on = [
    linode_instance.nat_a,
    linode_instance.nat_b
  ]
}

# host_vars (single)
resource "local_file" "hostvars_nat_a_single" {
  count    = local.is_multi ? 0 : 1
  filename = "${path.module}/../ansible/host_vars/nat-a.yml"
  content  = <<-EOT
# Auto-generated by Terraform — do not edit manually
vlan_if: eth1
ct_local_ip: "${trimsuffix(var.nat_a_vlan_ip, "/24")}"
ct_peer_ip:  "${trimsuffix(var.nat_b_vlan_ip, "/24")}"
EOT

  depends_on = [
    linode_instance.nat_a,
    linode_instance.nat_b,
    null_resource.create_hostvars_dir
  ]
}

resource "local_file" "hostvars_nat_b_single" {
  count    = local.is_multi ? 0 : 1
  filename = "${path.module}/../ansible/host_vars/nat-b.yml"
  content  = <<-EOT
# Auto-generated by Terraform — do not edit manually
vlan_if: eth1
ct_local_ip: "${trimsuffix(var.nat_b_vlan_ip, "/24")}"
ct_peer_ip:  "${trimsuffix(var.nat_a_vlan_ip, "/24")}"
EOT

  depends_on = [
    linode_instance.nat_a,
    linode_instance.nat_b,
    null_resource.create_hostvars_dir
  ]
}

# -----------------------------------------------------------------------------
# Inventory (multi): one group per pair + [nat:children]
# -----------------------------------------------------------------------------
resource "null_resource" "create_groupvars_dir" {
  count = local.is_multi ? 1 : 0
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = "mkdir -p ../ansible/group_vars"
  }
}

resource "local_file" "ansible_inventory_multi" {
  count    = local.is_multi ? 1 : 0
  filename = "${path.module}/../ansible/inventory.ini"

  content = join("\n", flatten([
    "# Auto-generated by Terraform — multi-pair inventory",
    "[nat:children]",
    [for p in local.pair_names : "nat_${p}"],
    "",
    flatten([
      for p in local.pair_names : [
        "[nat_${p}]",
        format("%s-a ansible_host=%s state=MASTER priority=150",
          p,
          try(tolist(linode_instance.multi["${p}-a"].ipv4)[0], "")
        ),
        format("%s-b ansible_host=%s state=BACKUP priority=100",
          p,
          try(tolist(linode_instance.multi["${p}-b"].ipv4)[0], "")
        ),
        "",
        "[nat_${p}:vars]",
        "ansible_user=root",
        "pub_if=eth0",
        "vlan_if=eth1",
        format("vlan_vip=%s", try(local.nat_pairs_by_name[p].vlan_vip, "")),
        format("shared_ipv4=%s", try(local.nat_pairs_by_name[p].shared_ipv4, "")),
        ""
      ]
    ]),
    "",
    "[nat:vars]",
    "dcid=${var.dcid}"
  ]))

  depends_on = [linode_instance.multi]
}

# group_vars per pair (multi)
resource "local_file" "group_vars_per_pair" {
  for_each = local.is_multi ? toset(local.pair_names) : toset([])

  filename = "${path.module}/../ansible/group_vars/nat_${each.key}.yml"

  content = <<-YAML
    # Auto-generated by Terraform. Do not edit by hand.
    # Pair: ${each.key}
    fip: "${try(local.nat_pairs_by_name[each.key].shared_ipv4, "")}"
    vlan_vip: "${try(local.nat_pairs_by_name[each.key].vlan_vip, "")}"

    # VRRP parameters
    vrrp_id: ${try(local.nat_pairs_by_name[each.key].vrrp_id, 50 + index(local.pair_names, each.key))}
    vrrp_instance: "VGW1"
    vrrp_interface: "eth1"
    vrrp_auth_pass: "${each.key}-pass"

    # Interfaces
    pub_if: "eth0"
    vlan_if: "eth1"
  YAML

  depends_on = [null_resource.create_groupvars_dir]
}

# nat common group_vars (exists in both modes)
resource "local_file" "group_vars_nat_common" {
  filename = "${path.module}/../ansible/group_vars/nat.yml"
  content  = <<-YAML
# Auto-generated by Terraform. Do not edit by hand.
dcid: ${var.dcid}
YAML
}

# host_vars per node (multi)
resource "local_file" "hostvars_per_node" {
  for_each   = local.is_multi ? { for m in local.members_flat : m.label => m } : {}
  filename   = "${path.module}/../ansible/host_vars/${each.key}.yml"
  content    = <<-EOT
# Auto-generated by Terraform — do not edit manually
vlan_if: eth1
ct_local_ip: "${local.local_ip_by_label[each.key]}"
ct_peer_ip:  "${local.peer_ip_by_label[each.key]}"
nat_ha_sync_iface: "${try(var.sync_iface, "eth2")}"
nat_ha_sync_ip_self: "${local.local_ip_by_label[each.key]}"
nat_ha_sync_ip_peer: "${local.peer_ip_by_label[each.key]}"
EOT
  depends_on = [linode_instance.multi, null_resource.create_hostvars_dir]
}
