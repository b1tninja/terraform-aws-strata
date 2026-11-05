# Layered stacks: a model artefact, then serving policies on top

Two Terraform stacks, two states, one set of weights.

```
base/        owns the 128 GB artefact:  weights snapshot + its ID, size, model, family
uncensored/  owns one serving policy:    the 267,552-byte vector, its gates, one instance
```

```bash
cd base       && terraform init && terraform apply -var="subnet_id=subnet-0abc..."
cd ../uncensored && terraform init && terraform apply
```

`uncensored/` reads `base/` through `data.terraform_remote_state`, and passes the model
and family it finds there into the hook's gates — so a snapshot of some model the vector
was never measured on fails at **plan** time, not at boot.

## Why split the state at all

- **`terraform destroy` in `uncensored/` cannot delete the snapshot.** It does not own it.
  The expensive artefact outlives every policy built on it.
- A stock stack and a steered stack can be applied, rolled and gated **independently**,
  by different people, with different IAM.
- Adding a third policy (another vector, another layer range, another licence) is a third
  directory of about this length, not a change to the core module.

| | base | uncensored |
|---|---|---|
| owns | weights snapshot | one instance + the vector |
| apply time | ~40 min (download + convert) | ~10 min (restore + load + one restart) |
| destroy | deletes 128 GB of work | leaves the snapshot alone |

## Backends

The example uses `backend = "local"` plus a relative `path` so it works on a laptop with
no setup. For real use give both stacks the same S3 backend and point the data source at
it:

```hcl
data "terraform_remote_state" "base" {
  backend = "s3"

  config = {
    bucket = "my-terraform-state"
    key    = "strata/base/terraform.tfstate"
    region = "us-east-1"
  }
}
```

## Caveats, stated plainly

- **Order matters.** `terraform_remote_state` needs `base` applied first; there is no
  `depends_on` across stacks. Apply order is part of the interface here.
- A **boot hook is opaque text**, so Terraform cannot check that it matches the boot
  script. The contract is asserted in [`../../tests/boot_hooks`](../../tests/boot_hooks),
  not by the type system.
- The steered stack sets `default_on = true`, so its endpoint serves projected output
  unless a caller passes `"experimental_speed_projection": false`. If you want the
  opposite posture, leave the default and let callers opt in — see
  [`../nvfp4-uncensored`](../nvfp4-uncensored).
- Removing refusals removes a safety behaviour: you are responsible for what the model
  writes with it on.
