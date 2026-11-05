# strata-instance

Runs one Strata instance from an AMI, with its data volume, security group and TTL
shutdown, rendering the shared boot script from `../strata-ami/user_data/boot.sh.tpl`.

For most cases use the **root module**, which also wires VPC lookup, IAM, Secrets Manager
and EventBridge Scheduler. Reach for this one when you already have an AMI, a subnet and
a security group and want a single instance without the rest.

It takes the same `boot_hooks` input as the root module, so behaviour is composed one way
only, whichever entrypoint you use; the pins for the shipped hook live in
`modules/strata-control-vector`.
