# Values for Trivy's Terraform parser only - see trivy.yaml. Nothing here is used by a real
# `terraform plan`; the numbers mirror the module's own defaults so the scan evaluates the same
# shape a default deployment produces.
#
# Limit worth stating: one scan evaluates one branch. weights_snapshot_id = "" selects the
# "download on first boot" volume rather than the snapshot-restored one. That is acceptable here
# because every branch defines its block device with `encrypted = true` as a literal, so a finding
# in one branch would appear in all of them.

region                     = "us-east-1"
weights_snapshot_id        = ""
use_bundled_ami            = false
bundled_data_volume_device = "/dev/sdb"
provisioned_iops           = 16000
provisioned_throughput     = 1000

</parameter>
<parameter=new_text>
# Values for Trivy's Terraform parser only - see trivy.yaml. Nothing here is used by a real
# `terraform plan`; the numbers mirror the module's own defaults so the scan evaluates the same
# shape a default deployment produces.
#
# Limit worth stating: one scan evaluates one branch. weights_snapshot_id = "" selects the
# "download on first boot" volume rather than the snapshot-restored one. That is acceptable here
# because every branch defines its block device with `encrypted = true` as a literal, so a finding
# in one branch would appear in all of them.

region                     = "us-east-1"
weights_snapshot_id        = ""
use_bundled_ami            = false
bundled_data_volume_device = "/dev/sdb"
provisioned_iops           = 16000
provisioned_throughput     = 1000
