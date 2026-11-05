# strata-ami-bundled

Builds an AMI with the model weights **inside the image** rather than on a data volume,
by provisioning a staging instance, writing the weights to its root volume and
registering the result as an AMI. Boot then mounts a device that already contains them.

Used by the root module when `use_bundled_ami = true`; `strata-ami` is the alternative
that bundles only the container image and keeps weights on a volume or snapshot.
