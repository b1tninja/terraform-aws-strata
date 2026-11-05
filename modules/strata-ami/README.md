# strata-ami

Builds the GPU AMI: an Ubuntu Deep Learning base image plus Docker, the NVIDIA container
toolkit and a pre-pulled `ghcr.io/niko1221/strata` image, so a boot does not wait on a
multi-gigabyte pull.

The root module builds one in `make_ami` mode and otherwise selects a published DL AMI
with its own `aws_ami` data source. `user_data/boot.sh.tpl` in this directory is the boot
script the **root module and `strata-instance` both render** — it is not only for AMIs.
