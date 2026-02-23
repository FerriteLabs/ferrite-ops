#!/usr/bin/env bash
# ferrite-cost-estimate — Compare infrastructure costs: Redis (memory-only) vs Ferrite (tiered storage)
#
# Usage:
#   ./cost-estimate.sh --dataset-size 100 --hot-ratio 0.2 --cloud aws
#   ./cost-estimate.sh --dataset-size 500 --hot-ratio 0.1 --cloud gcp --region us-east1
#
# All costs are monthly estimates in USD.

set -euo pipefail

# Defaults
DATASET_SIZE_GB=100
HOT_RATIO=0.2
CLOUD="aws"
REGION=""
REPLICATION=1

# Cloud pricing (approximate $/GB/month as of 2026)
# Memory (ElastiCache/MemoryStore/Azure Cache)
AWS_MEMORY_PER_GB=12.50
GCP_MEMORY_PER_GB=13.00
AZURE_MEMORY_PER_GB=12.80

# SSD (EBS gp3 / Persistent Disk SSD / Azure Managed Disk)
AWS_SSD_PER_GB=0.08
GCP_SSD_PER_GB=0.17
AZURE_SSD_PER_GB=0.12

# Object storage (S3 / GCS / Azure Blob)
AWS_S3_PER_GB=0.023
GCP_GCS_PER_GB=0.020
AZURE_BLOB_PER_GB=0.018

usage() {
    cat <<EOF
Ferrite Tiered Storage Cost Calculator

Compare monthly infrastructure costs between Redis (memory-only) and Ferrite (tiered storage).

USAGE:
    $(basename "$0") [OPTIONS]

OPTIONS:
    --dataset-size <GB>    Total dataset size in GB (default: 100)
    --hot-ratio <0.0-1.0>  Fraction of data accessed frequently (default: 0.2)
    --cloud <aws|gcp|azure> Cloud provider (default: aws)
    --replication <N>       Replication factor (default: 1)
    -h, --help              Show this help

EXAMPLES:
    $(basename "$0") --dataset-size 100 --hot-ratio 0.2 --cloud aws
    $(basename "$0") --dataset-size 500 --hot-ratio 0.1 --cloud gcp
    $(basename "$0") --dataset-size 1000 --hot-ratio 0.05 --cloud azure --replication 3
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dataset-size) DATASET_SIZE_GB="$2"; shift 2 ;;
        --hot-ratio) HOT_RATIO="$2"; shift 2 ;;
        --cloud) CLOUD="$2"; shift 2 ;;
        --replication) REPLICATION="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Select pricing based on cloud
case $CLOUD in
    aws)
        MEMORY_PRICE=$AWS_MEMORY_PER_GB
        SSD_PRICE=$AWS_SSD_PER_GB
        OBJECT_PRICE=$AWS_S3_PER_GB
        CLOUD_NAME="AWS"
        ;;
    gcp)
        MEMORY_PRICE=$GCP_MEMORY_PER_GB
        SSD_PRICE=$GCP_SSD_PER_GB
        OBJECT_PRICE=$GCP_GCS_PER_GB
        CLOUD_NAME="GCP"
        ;;
    azure)
        MEMORY_PRICE=$AZURE_MEMORY_PER_GB
        SSD_PRICE=$AZURE_SSD_PER_GB
        OBJECT_PRICE=$AZURE_BLOB_PER_GB
        CLOUD_NAME="Azure"
        ;;
    *)
        echo "Error: Unknown cloud provider '$CLOUD'. Use aws, gcp, or azure."
        exit 1
        ;;
esac

# Calculate tier sizes for Ferrite
HOT_GB=$(echo "$DATASET_SIZE_GB * $HOT_RATIO" | bc)
WARM_GB=$(echo "$DATASET_SIZE_GB * (1 - $HOT_RATIO) * 0.3" | bc)
COLD_GB=$(echo "$DATASET_SIZE_GB * (1 - $HOT_RATIO) * 0.7" | bc)

# Redis: everything in memory
REDIS_MEMORY_GB=$DATASET_SIZE_GB
REDIS_COST=$(echo "$REDIS_MEMORY_GB * $MEMORY_PRICE * $REPLICATION" | bc)

# Ferrite: tiered across memory + SSD + object storage
FERRITE_MEMORY_COST=$(echo "$HOT_GB * $MEMORY_PRICE * $REPLICATION" | bc)
FERRITE_SSD_COST=$(echo "$WARM_GB * $SSD_PRICE * $REPLICATION" | bc)
FERRITE_OBJECT_COST=$(echo "$COLD_GB * $OBJECT_PRICE * $REPLICATION" | bc)
FERRITE_COST=$(echo "$FERRITE_MEMORY_COST + $FERRITE_SSD_COST + $FERRITE_OBJECT_COST" | bc)

# Savings
SAVINGS=$(echo "$REDIS_COST - $FERRITE_COST" | bc)
if [ "$(echo "$REDIS_COST > 0" | bc)" -eq 1 ]; then
    SAVINGS_PCT=$(echo "scale=1; ($SAVINGS * 100) / $REDIS_COST" | bc)
else
    SAVINGS_PCT=0
fi

# Output
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Ferrite Tiered Storage Cost Calculator"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Configuration"
echo "  ─────────────────────────────────────────────────────────"
printf "  Dataset Size:      %'d GB\n" "$DATASET_SIZE_GB"
printf "  Hot Data Ratio:    %.0f%%\n" "$(echo "$HOT_RATIO * 100" | bc)"
printf "  Cloud Provider:    %s\n" "$CLOUD_NAME"
printf "  Replication:       %dx\n" "$REPLICATION"
echo ""
echo "  Redis (memory-only)                        Monthly Cost"
echo "  ─────────────────────────────────────────────────────────"
printf "  Memory:            %8.1f GB × \$%.2f     \$%'.2f\n" "$REDIS_MEMORY_GB" "$MEMORY_PRICE" "$REDIS_COST"
printf "  Total:                                      \033[1;31m\$%'.2f\033[0m\n" "$REDIS_COST"
echo ""
echo "  Ferrite (tiered storage)                   Monthly Cost"
echo "  ─────────────────────────────────────────────────────────"
printf "  Hot  (memory):     %8.1f GB × \$%.2f     \$%'.2f\n" "$HOT_GB" "$MEMORY_PRICE" "$FERRITE_MEMORY_COST"
printf "  Warm (SSD):        %8.1f GB × \$%.4f   \$%'.2f\n" "$WARM_GB" "$SSD_PRICE" "$FERRITE_SSD_COST"
printf "  Cold (object):     %8.1f GB × \$%.4f   \$%'.2f\n" "$COLD_GB" "$OBJECT_PRICE" "$FERRITE_OBJECT_COST"
printf "  Total:                                      \033[1;32m\$%'.2f\033[0m\n" "$FERRITE_COST"
echo ""
echo "  ─────────────────────────────────────────────────────────"
printf "  Monthly Savings:                            \033[1;32m\$%'.2f (%s%%)\033[0m\n" "$SAVINGS" "$SAVINGS_PCT"
echo "  ═══════════════════════════════════════════════════════════"
echo ""
echo "  Note: Estimates based on on-demand pricing. Reserved instances"
echo "  and committed use discounts may further reduce costs."
echo ""
