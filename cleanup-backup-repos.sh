#!/bin/bash

################################################################################
# Script: cleanup-backup-repos.sh
# Description: Removes backed-up PAYG repository files from converted SLES VMs
# Usage: ./cleanup-backup-repos.sh -g <resource-group> [-n <vm-name>]
################################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 -g <resource-group> [-n <vm-name>] [-y]

Required parameters:
    -g                Resource group name

Optional parameters:
    -n                VM name (if specified, only clean this VM; otherwise clean all SLES VMs in resource group)
    -p                Number of parallel jobs (default: 1). Recommended: 5
    -y                Auto-confirm (skip confirmation prompt)
    -h                Display this help message

Description:
    This script removes the backed-up PAYG repository files from converted SLES VMs.
    The conversion script backs up repos to /etc/zypp/repos.d.backup/ before conversion.
    Use this script once you've verified the conversion was successful and no longer need the backups.

Examples:
    # Clean up single VM
    $0 -g prod-sap-rg -n sap-vm-01
    
    # Clean up all SLES VMs in resource group
    $0 -g prod-sap-rg
    
    # Auto-confirm without prompts
    $0 -g prod-sap-rg -y

Safety:
    - Only removes files from /etc/zypp/repos.d.backup/ directory
    - Does not affect current repository configuration in /etc/zypp/repos.d/
    - Lists VMs and backup contents before deletion
EOF
    exit 1
}

# Parse command line arguments
AUTO_CONFIRM=false
PARALLEL_JOBS=1

while getopts "g:n:p:yh" opt; do
    case $opt in
        g) RESOURCE_GROUP="$OPTARG" ;;
        n) VM_NAME="$OPTARG" ;;
        p) PARALLEL_JOBS="$OPTARG" ;;
        y) AUTO_CONFIRM=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [[ -z "$RESOURCE_GROUP" ]]; then
    log_error "Missing required parameter: -g <resource-group>"
    usage
fi

# Validate parallel jobs parameter
if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [ "$PARALLEL_JOBS" -lt 1 ]; then
    log_error "Parallel jobs must be a positive integer"
    exit 1
fi

log_info "=========================================="
log_info "Repository Backup Cleanup"
log_info "=========================================="

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    log_error "Azure CLI is not installed. Please install it first."
    exit 1
fi

# Check if logged into Azure
log_info "Checking Azure CLI authentication..."
if ! az account show &> /dev/null; then
    log_error "Not logged into Azure. Please run 'az login' first."
    exit 1
fi

# Get current subscription info
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
log_info "Using subscription: $SUBSCRIPTION_NAME"
log_info "Resource Group: $RESOURCE_GROUP"

# Get list of VMs to process
if [[ -n "$VM_NAME" ]]; then
    # Single VM mode
    log_info "Mode: Single VM"
    log_info "VM Name: $VM_NAME"
    
    # Verify VM exists
    log_info "Verifying VM exists..."
    if ! az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" &> /dev/null; then
        log_error "VM '$VM_NAME' not found in resource group '$RESOURCE_GROUP'"
        exit 1
    fi
    
    VMS=("$VM_NAME")
else
    # Resource group mode - get all SLES VMs
    log_info "Mode: Resource Group (all SLES VMs)"
    log_info "Discovering SLES VMs in resource group..."
    
    mapfile -t VMS < <(az vm list -g "$RESOURCE_GROUP" \
        --query "[?contains(storageProfile.imageReference.offer, 'sles') || contains(storageProfile.imageReference.offer, 'SLES')].name" \
        -o tsv | tr -d '\r')
    
    if [ ${#VMS[@]} -eq 0 ]; then
        log_error "No SLES VMs found in resource group '$RESOURCE_GROUP'"
        exit 1
    fi
    
    log_info "Found ${#VMS[@]} SLES VM(s):"
    for vm in "${VMS[@]}"; do
        log_info "  - $vm"
    done
fi

echo ""
log_info "Checking for backup directories on VMs$([ $PARALLEL_JOBS -gt 1 ] && echo " (parallel: $PARALLEL_JOBS)")..."

# Create temporary directory for results
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Check each VM for backup directory (parallel)
if [[ $PARALLEL_JOBS -gt 1 ]]; then
    for vm in "${VMS[@]}"; do
        while [ $(jobs -r | wc -l) -ge $PARALLEL_JOBS ]; do
            sleep 1
        done
        (
            BACKUP_CHECK=$(az vm run-command invoke \
                -g "$RESOURCE_GROUP" \
                -n "$vm" \
                --command-id RunShellScript \
                --scripts "if [ -d /etc/zypp/repos.d.backup ]; then ls -lh /etc/zypp/repos.d.backup/ 2>/dev/null | tail -n +2 | wc -l; else echo '0'; fi" \
                --query 'value[0].message' -o tsv 2>/dev/null | grep -o '[0-9]*' | head -1)
            echo "$BACKUP_CHECK" > "$TEMP_DIR/check_$vm"
        ) &
    done
    
    echo -n "  Checking: "
    while [ $(jobs -r | wc -l) -gt 0 ]; do
        echo -n "."
        sleep 2
    done
    echo " Done"
    echo ""
    
    # Collect results
    VMS_WITH_BACKUPS=()
    for vm in "${VMS[@]}"; do
        BACKUP_CHECK=$(cat "$TEMP_DIR/check_$vm" 2>/dev/null)
        if [[ -n "$BACKUP_CHECK" && "$BACKUP_CHECK" -gt 0 ]]; then
            log_info "  ✓ $vm: $BACKUP_CHECK file(s) in backup"
            VMS_WITH_BACKUPS+=("$vm")
        else
            log_warn "  ⊙ $vm: No backup found"
        fi
    done
else
    # Sequential check
    VMS_WITH_BACKUPS=()
    for vm in "${VMS[@]}"; do
        log_info "Checking VM: $vm"
        
        BACKUP_CHECK=$(az vm run-command invoke \
            -g "$RESOURCE_GROUP" \
            -n "$vm" \
            --command-id RunShellScript \
            --scripts "if [ -d /etc/zypp/repos.d.backup ]; then ls -lh /etc/zypp/repos.d.backup/ 2>/dev/null | tail -n +2 | wc -l; else echo '0'; fi" \
            --query 'value[0].message' -o tsv 2>/dev/null | grep -o '[0-9]*' | head -1)
        
        if [[ -n "$BACKUP_CHECK" && "$BACKUP_CHECK" -gt 0 ]]; then
            log_info "  ✓ Backup directory exists: $BACKUP_CHECK file(s) in /etc/zypp/repos.d.backup/"
            VMS_WITH_BACKUPS+=("$vm")
        else
            log_warn "  ⊙ No backup directory found (already cleaned or never converted)"
        fi
        echo ""
    done
fi

echo ""

if [[ ${#VMS_WITH_BACKUPS[@]} -eq 0 ]]; then
    log_info "No backup directories found on any VMs. Nothing to clean up."
    exit 0
fi

# Confirm before proceeding
log_warn "This script will PERMANENTLY DELETE backed-up repository files from ${#VMS_WITH_BACKUPS[@]} VM(s):"
echo "  - Location: /etc/zypp/repos.d.backup/"
echo "  - These are the original PAYG repository files backed up during conversion"
echo "  - This action cannot be undone"
echo ""
log_warn "Only proceed if you have verified the conversion was successful!"
echo ""

if [[ "$AUTO_CONFIRM" == true ]]; then
    log_info "Auto-confirm enabled, proceeding with cleanup"
else
    read -p "Do you want to proceed with cleanup? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Operation cancelled by user"
        exit 0
    fi
fi

# Perform cleanup (only on VMs with backups)
SUCCESSFUL=0
FAILED=0

if [[ $PARALLEL_JOBS -gt 1 ]]; then
    log_info "Cleaning up ${#VMS_WITH_BACKUPS[@]} VMs in parallel (max $PARALLEL_JOBS concurrent)..."
    
    for vm in "${VMS_WITH_BACKUPS[@]}"; do
        while [ $(jobs -r | wc -l) -ge $PARALLEL_JOBS ]; do
            sleep 1
        done
        (
            CLEANUP_RESULT=$(az vm run-command invoke \
                -g "$RESOURCE_GROUP" \
                -n "$vm" \
                --command-id RunShellScript \
                --scripts "
if [ -d /etc/zypp/repos.d.backup ]; then
    FILE_COUNT=\$(ls -1 /etc/zypp/repos.d.backup/ 2>/dev/null | wc -l)
    rm -rf /etc/zypp/repos.d.backup/
    if [ \$? -eq 0 ]; then
        echo \"SUCCESS: Removed \$FILE_COUNT file(s)\"
    else
        echo \"ERROR: Failed to remove backup directory\"
    fi
else
    echo \"SKIP: No backup directory found\"
fi
" --query 'value[0].message' -o tsv 2>&1)
            
            if echo "$CLEANUP_RESULT" | grep -q "SUCCESS:"; then
                echo "SUCCESS|$vm" > "$TEMP_DIR/cleanup_$vm"
            else
                echo "FAILED|$vm" > "$TEMP_DIR/cleanup_$vm"
            fi
        ) &
    done
    
    echo -n "  Cleaning: "
    while [ $(jobs -r | wc -l) -gt 0 ]; do
        echo -n "."
        sleep 2
    done
    echo " Done"
    echo ""
    
    # Collect results
    for vm in "${VMS_WITH_BACKUPS[@]}"; do
        RESULT=$(cat "$TEMP_DIR/cleanup_$vm" 2>/dev/null)
        if [[ "$RESULT" == SUCCESS* ]]; then
            ((SUCCESSFUL++))
            log_info "  ✓ $vm: Cleanup successful"
        else
            ((FAILED++))
            log_error "  ✗ $vm: Cleanup failed"
        fi
    done
else
    # Sequential cleanup
    for vm in "${VMS_WITH_BACKUPS[@]}"; do
        log_info "Processing VM: $vm"
        
        CLEANUP_RESULT=$(az vm run-command invoke \
            -g "$RESOURCE_GROUP" \
            -n "$vm" \
            --command-id RunShellScript \
            --scripts "
if [ -d /etc/zypp/repos.d.backup ]; then
    FILE_COUNT=\$(ls -1 /etc/zypp/repos.d.backup/ 2>/dev/null | wc -l)
    rm -rf /etc/zypp/repos.d.backup/
    if [ \$? -eq 0 ]; then
        echo \"SUCCESS: Removed \$FILE_COUNT file(s) from /etc/zypp/repos.d.backup/\"
    else
        echo \"ERROR: Failed to remove backup directory\"
        exit 1
    fi
else
    echo \"SKIP: No backup directory found\"
fi
" --query 'value[0].message' -o tsv 2>&1)
        
        if echo "$CLEANUP_RESULT" | grep -q "SUCCESS:"; then
            ((SUCCESSFUL++))
            log_info "  ✓ Cleanup successful"
            echo "$CLEANUP_RESULT" | grep "SUCCESS:" | sed 's/\[stdout\]//g' | sed 's/^/    /'
        else
            ((FAILED++))
            log_error "  ✗ Cleanup failed"
            echo "$CLEANUP_RESULT" | sed 's/^/    /'
        fi
        echo ""
    done
fi

# Final Summary
echo ""
log_info "=========================================="
log_info "Cleanup Summary"
log_info "=========================================="
log_info "Resource Group: $RESOURCE_GROUP"
log_info "Total VMs Found: ${#VMS[@]}"
log_info "VMs with Backups: ${#VMS_WITH_BACKUPS[@]}"
log_info "Successful: $SUCCESSFUL"
log_info "Skipped (no backup): $((${#VMS[@]} - ${#VMS_WITH_BACKUPS[@]}))"
log_info "Failed: $FAILED"
log_info "=========================================="

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi

exit 0
