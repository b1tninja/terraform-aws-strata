# strata-instance

Runs one Strata instance from an AMI, with its data volume, security group and TTL
shutdown, rendering the shared boot script from `../strata-ami/user_data/boot.sh.tpl`.

For most cases use the **root module**, which also wires VPC lookup, IAM, Secrets Manager
and EventBridge Scheduler. Reach for this one when you already have an AMI, a subnet and
a security group and want a single instance without the rest.

It takes the control-vector settings as one object, `uncensor`, so the pins live in the
root module's `uncensor.tf` and cannot drift between the two callers.
