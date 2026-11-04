# Cost Breakdown

## Per-Instance-Hour (while running)

| Instance Type | On-Demand | Spot (~65% off) | GPUs | RAM | Best For |
|--------------|-----------|-----------------|------|-----|----------|
| g6e.8xlarge | ~$4.20/hr | ~$1.47/hr | 1×L40S (48GB) | 256 GB | IQ2_XS, IQ3_XXS, IQ3_S |
| g6e.12xlarge | ~$10.30/hr | ~$3.60/hr | 4×L40S (192GB) | 384 GB | Q8_0, DeepSeek |
| g6e.24xlarge | ~$15.10/hr | ~$5.30/hr | 4×L40S (192GB) | 768 GB | DeepSeek 2.25bpw |
| g5.12xlarge | ~$5.67/hr | ~$1.99/hr | 4×A10G (96GB) | 192 GB | IQ2_XS |
| g5.24xlarge | ~$8.14/hr | ~$2.85/hr | 4×A10G (96GB) | 384 GB | IQ3_S |

## Fixed Costs (24/7)

| Item | Cost | Notes |
|------|------|-------|
| EBS Fast Snapshot Restore | $0.75/hr per snapshot per AZ = **$540/month** | Only needed if instances launch frequently |
| EBS snapshot storage | $0.05/GB-month × 250 GB = **$12.50/month** | The weights themselves at rest |
| AMI storage | $0.05/GB-month × ~5 GB = **$0.25/month** | AMI is small (image + OS) |

## Per-Use Cost (ephemeral, 1 hour)

| Component | Cost |
|-----------|------|
| g6e.8xlarge on-demand (1hr) | $4.20 |
| g6e.8xlarge spot (1hr) | $1.47 |
| Data volume (250GB gp3, 1hr) | $0.05 |
| Root volume (30GB gp3, 1hr) | $0.01 |
| FSR (1hr, if already enabled) | $0.75 (amortized across uses) |
| **Total (spot, FSR shared across 100 uses)** | **~$2.30** |
| **Total (on-demand, FSR shared)** | **~$5.00** |

## Optimization Tips

1. **Use spot instances** — 60-70% savings for ephemeral workloads
2. **Enable FSR only in your primary AZ** — saves $0.75/hr × (N-1) unused AZs
3. **Disable FSR when not actively using** — save $540/month during downtime
4. **TTL auto-terminate** — prevent forgotten instances burning money
5. **One snapshot, many instances** — FSR credits are shared across volume creations

## Monthly Cost Scenarios

| Scenario | Description | Est. Monthly |
|----------|-------------|-------------|
| Development | 5 instances/week × 1hr × spot, FSR always on | ~$760 |
| CI/CD benchmarks | 1 benchmark/day × 30min × spot, FSR always on | ~$570 |
| Production always-on | 1 g6e.8xlarge on-demand, FSR on | ~$3,650 |
| Cost-conscious dev | 2 instances/week × 1hr × spot, FSR only during work | ~$120 |
