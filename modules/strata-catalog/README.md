# strata-catalog

Model and instance facts, and the validation that reads them. No providers, no
resources: it is data plus checks, so it plans without AWS credentials.

The root module calls it to derive `data_volume_size`, to reject a model/family
combination that upstream does not publish, to reject compute the engine has no build
for (P5/P6 have no engine package — the container exits 3 before loading anything), and
to decide whether a control-vector hook may be attached at all (lineage and licence).

## Usage

```hcl
module "catalog" {
  source = "./modules/strata-catalog"

  model         = "NVFP4"
  model_family  = "nvfp4"
  instance_type = "g7e.8xlarge"
}

data_volume_size = module.catalog.suggested_data_volume_gb
```

Every field records the upstream file, line and the date it was read; the test harness in
[`tests/catalog`](../../tests/catalog) asserts the invariants during `terraform plan`
(`make catalog-test`).
