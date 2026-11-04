name: PullStrataImage
description: Pre-pulls the Strata Docker image into the AMI so instances start without a registry pull
schemaVersion: 1.0

phases:
  - name: build
    steps:
      - name: PullStrataContainerImage
        action: ExecuteBash
        inputs:
          commands:
            - |
              set -euxo pipefail
              IMAGE="ghcr.io/niko1221/strata:${strata_image_tag}"
              echo "Pulling $IMAGE..."
              docker pull "$IMAGE"
              docker image inspect "$IMAGE" --format='Image size: {{.Size}} bytes'
              echo "Strata image cached in AMI."
