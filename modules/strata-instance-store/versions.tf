terraform {
  required_version = ">= 1.5.0"
  # No providers: this module renders boot text and checks numbers the caller already has from
  # the catalog, so it can be planned - and its tests run - without AWS credentials.
}
