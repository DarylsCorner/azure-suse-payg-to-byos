#!/bin/bash

################################################################################
# Script: convert-suse-payg-to-byos.sh
# Description: Converts Azure SUSE PAYG VM to BYOS with SUSE Manager registration
# Usage: ./convert-suse-payg-to-byos.sh -g <resource-group> -n <vm-name> -s <suse-manager-url>
################################################################################

# Note: Not using 'set -e' because we handle errors explicitly in convert_vm function

# Log directory (log file will be created after parsing arguments)
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to log to both console and file
log_to_file() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Only write to log file if it has been initialized
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$timestamp] $1" >> "$LOG_FILE"
    fi
}

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    log_to_file "[INFO] $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    log_to_file "[WARN] $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log_to_file "[ERROR] $1"
}

# Function to validate URL format
validate_url() {
    local url="$1"
    
    # Check for empty URL
    if [[ -z "$url" ]]; then
        log_error "SUSE Manager URL cannot be empty"
        return 1
    fi
    
    # Check format: valid hostname (alphanumeric, dots, hyphens only)
    # Must start and end with alphanumeric, dots allowed between segments
    if [[ ! "$url" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "Invalid SUSE Manager URL format: $url"
        log_error "URL must be a valid hostname (e.g., suse-manager.company.com)"
        return 1
    fi
    
    # Check for dangerous characters that could be used for injection
    if [[ "$url" =~ [\;\&\|\$\`\(\)\<\>\\] ]] || [[ "$url" == *"'"* ]] || [[ "$url" == *'"'* ]]; then
        log_error "URL contains invalid/dangerous characters: $url"
        log_error "Only alphanumeric characters, dots, and hyphens are allowed"
        return 1
    fi
    
    log_info "URL validation passed: $url"
    return 0
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 -g <resource-group> [OPTIONS]

Required parameters:
    -g                Resource group name

SUSE Manager Registration (choose one mode):
    -s                SUSE Manager server URL (e.g., suse-manager.example.com)
                      Required unless using --skip-registration
    
    --skip-registration
                      Skip SUSE Manager registration (cleanup and license change only)
                      Use when you have your own registration method (e.g., Ansible playbook)

Activation Key (required for SUSE Manager registration, not needed with --skip-registration or -t):
    --keyvault        Azure Key Vault name containing the activation key (most secure)
    --secret-name     Secret name in Key Vault for the activation key
                      Example: --keyvault MyVault --secret-name suse-activation-key
    
    Environment:      Set SUSE_ACTIVATION_KEY environment variable
                      Example: export SUSE_ACTIVATION_KEY="your-key"

Optional parameters:
    -n                VM name (if specified, only convert this VM; otherwise convert all SLES VMs in resource group)
    -p                Number of parallel jobs (default: 1 for sequential). Recommended: 2-4 for parallel execution
    -t                Test mode - skips SUSE Manager registration (for testing without SUSE Manager)
    -y                Auto-confirm (skip confirmation prompt)
    -h                Display this help message

Examples:
    # Production: Using Key Vault (recommended)
    $0 -g prod-sap-rg -s suse-manager.company.com \\
       --keyvault WorkloadKeyVault --secret-name suse-activation-key
    
    # Development: Using environment variable
    export SUSE_ACTIVATION_KEY="dev-activation-key"
    $0 -g dev-rg -s suse-manager.company.com
    
    # Test mode (no activation key needed)
    $0 -g test-rg -s suse-manager.company.com -t
    
    # Parallel execution with Key Vault
    $0 -g prod-sap-rg -s suse-manager.company.com \\
       --keyvault WorkloadKeyVault --secret-name suse-activation-key -p 3
    
    # Skip registration (use your own Ansible/Puppet/Chef for SUSE Manager registration)
    $0 -g prod-sap-rg --skip-registration -y

Security Notes:
    - Activation keys are retrieved securely from Key Vault or environment variables
    - Command-line activation key parameter (-k) has been removed for security
    - URLs are validated to prevent injection attacks
EOF
    exit 1
}

# Parse command line arguments
PARALLEL_JOBS=1
TEST_MODE=false
AUTO_CONFIRM=false
KEYVAULT_NAME=""
SECRET_NAME=""
SKIP_REGISTRATION=false

# Parse long options first
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --keyvault)
            KEYVAULT_NAME="$2"
            shift 2
            ;;
        --secret-name)
            SECRET_NAME="$2"
            shift 2
            ;;
        --skip-registration)
            SKIP_REGISTRATION=true
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore positional parameters for getopts
set -- "${ARGS[@]}"

# Parse short options
while getopts "g:n:s:p:tyh" opt; do
    case $opt in
        g) RESOURCE_GROUP="$OPTARG" ;;
        n) VM_NAME="$OPTARG" ;;
        s) SUSE_MANAGER_URL="$OPTARG" ;;
        p) PARALLEL_JOBS="$OPTARG" ;;
        t) TEST_MODE=true ;;
        y) AUTO_CONFIRM=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [[ -z "$RESOURCE_GROUP" ]]; then
    log_error "Missing required parameter: resource group (-g)"
    usage
fi

# Validate SUSE Manager URL unless skipping registration
if [[ "$SKIP_REGISTRATION" == false && -z "$SUSE_MANAGER_URL" ]]; then
    log_error "Missing required parameter: SUSE Manager URL (-s) or use --skip-registration"
    usage
fi

# Validate URL format (only if provided)
if [[ -n "$SUSE_MANAGER_URL" ]] && ! validate_url "$SUSE_MANAGER_URL"; then
    exit 1
fi

# Validate parallel jobs parameter
if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [ "$PARALLEL_JOBS" -lt 1 ]; then
    log_error "Parallel jobs must be a positive integer"
    exit 1
fi

# Create run-specific log directory and main log file
RUN_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_LOG_DIR="${LOG_DIR}/${RESOURCE_GROUP}_${RUN_TIMESTAMP}"
mkdir -p "$RUN_LOG_DIR"
LOG_FILE="${RUN_LOG_DIR}/main.log"

log_info "=========================================="
log_info "SUSE PAYG to BYOS Conversion"
log_info "=========================================="
log_info "Log file: $LOG_FILE"
if [[ "$SKIP_REGISTRATION" == true ]]; then
    log_warn "SKIP REGISTRATION MODE - Only cleanup and license change (use your own registration method)"
elif [[ "$TEST_MODE" == true ]]; then
    log_warn "TEST MODE ENABLED - SUSE Manager registration will be skipped"
fi
log_info "Starting SUSE PAYG to BYOS conversion process"
log_info "Resource Group: $RESOURCE_GROUP"
if [[ "$SKIP_REGISTRATION" == true ]]; then
    log_info "SUSE Manager URL: N/A (skip-registration mode)"
else
    log_info "SUSE Manager URL: $SUSE_MANAGER_URL"
fi
log_info "Execution Mode: $([ $PARALLEL_JOBS -eq 1 ] && echo 'Sequential' || echo "Parallel ($PARALLEL_JOBS jobs)")"
log_info "Skip Registration: $SKIP_REGISTRATION"
log_info "Test Mode: $TEST_MODE"

# Retrieve activation key from secure sources
ACTIVATION_KEY=""
SKIP_ACTIVATION_KEY=false

# In skip-registration mode, activation key is not needed
if [[ "$SKIP_REGISTRATION" == true ]]; then
    log_info "Skip registration mode: Activation key is not required"
    SKIP_ACTIVATION_KEY=true
# In test mode, activation key is optional
elif [[ "$TEST_MODE" == true ]]; then
    log_info "Test mode: Activation key is optional"
    SKIP_ACTIVATION_KEY=true
fi

# Try to retrieve activation key from Key Vault or environment variable
# Priority 1: Key Vault (most secure)
if [[ -n "$KEYVAULT_NAME" && -n "$SECRET_NAME" ]]; then
    log_info "Retrieving activation key from Key Vault: $KEYVAULT_NAME"
    ACTIVATION_KEY=$(az keyvault secret show \
        --vault-name "$KEYVAULT_NAME" \
        --name "$SECRET_NAME" \
        --query value -o tsv 2>&1)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to retrieve activation key from Key Vault"
        log_error "$ACTIVATION_KEY"
        exit 1
    fi
    
    log_info "✓ Activation key retrieved from Key Vault"
    
    # In test mode, show the retrieved key for verification
    if [[ "$TEST_MODE" == true ]]; then
        log_info "TEST MODE - Retrieved activation key: ${ACTIVATION_KEY:0:20}... (${#ACTIVATION_KEY} chars)"
    fi
# Priority 2: Environment variable
elif [[ -n "$SUSE_ACTIVATION_KEY" ]]; then
    ACTIVATION_KEY="$SUSE_ACTIVATION_KEY"
    log_info "✓ Using activation key from SUSE_ACTIVATION_KEY environment variable"
    
    # In test mode, show the retrieved key for verification
    if [[ "$TEST_MODE" == true ]]; then
        log_info "TEST MODE - Retrieved activation key: ${ACTIVATION_KEY:0:20}... (${#ACTIVATION_KEY} chars)"
    fi
# No activation key provided
else
    if [[ "$SKIP_ACTIVATION_KEY" == false ]]; then
        log_error "No activation key provided. Please use one of:"
        log_error "  1. Key Vault: --keyvault <vault-name> --secret-name <secret-name>"
        log_error "  2. Environment variable: export SUSE_ACTIVATION_KEY='your-key'"
        log_error "  3. Test mode: -t (skips SUSE Manager registration)"
        exit 1
    else
        log_info "Test mode: No activation key provided (will use simulated registration)"
    fi
fi

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
    
    log_info "Found ${#VMS[@]} SLES VM(s) to convert:"
    for vm in "${VMS[@]}"; do
        log_info "  - $vm"
    done
fi

# Confirm before proceeding
echo ""
log_warn "This script will perform the following actions on ${#VMS[@]} VM(s):"
echo "  1. Clean up PAYG SUSE registration on each VM"
if [[ "$SKIP_REGISTRATION" == true ]]; then
    echo "  2. SKIP SUSE Manager registration (use your own method)"
else
    echo "  2. Register each VM to SUSE Manager at $SUSE_MANAGER_URL"
fi
echo "  3. Change Azure license type to SLES_BYOS"
if [[ "$SKIP_REGISTRATION" == true ]]; then
    echo "  4. Validate cleanup completed"
else
    echo "  4. Validate repository configuration"
fi
echo ""

if [[ "$AUTO_CONFIRM" == true ]]; then
    log_info "Auto-confirm enabled, proceeding without confirmation"
else
    read -p "Do you want to proceed? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Operation cancelled by user"
        exit 0
    fi
fi

# Function to convert a single VM
convert_vm() {
    local CURRENT_VM="$1"
    local VM_NUMBER="$2"
    local TOTAL_VMS="$3"
    
    # Create VM-specific log file in run-specific directory
    local VM_LOG_FILE="${RUN_LOG_DIR}/${CURRENT_VM}.log"
    
    # Function to log to both main log and VM-specific log
    vm_log() {
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] $1" >> "$VM_LOG_FILE"
        echo "[$timestamp] [VM: $CURRENT_VM] $1" >> "$LOG_FILE"
    }
    
    vm_log ""
    vm_log "=========================================="
    vm_log "Processing VM $VM_NUMBER of $TOTAL_VMS"
    vm_log "=========================================="
    vm_log "VM-specific log: $VM_LOG_FILE"
    
    # Get current VM information
    vm_log "Retrieving VM information..."
    VM_INFO=$(az vm show -g "$RESOURCE_GROUP" -n "$CURRENT_VM" -o json 2>&1)
    if [ $? -ne 0 ]; then
        vm_log "ERROR: Failed to retrieve VM information"
        vm_log "$VM_INFO"
        return 1
    fi
    
    CURRENT_IMAGE=$(echo "$VM_INFO" | jq -r '.storageProfile.imageReference.offer // "N/A"')
    CURRENT_SKU=$(echo "$VM_INFO" | jq -r '.storageProfile.imageReference.sku // "N/A"')
    CURRENT_LICENSE=$(echo "$VM_INFO" | jq -r '.licenseType // "None"')
    
    vm_log "Current Image Offer: $CURRENT_IMAGE"
    vm_log "Current SKU: $CURRENT_SKU"
    vm_log "Current License Type: $CURRENT_LICENSE"
    
    # Check if VM is already BYOS
    if [[ "$CURRENT_LICENSE" == "SLES_BYOS" ]]; then
        vm_log "⊙ VM already has SLES_BYOS license - SKIPPING conversion"
        vm_log "If you need to re-register to SUSE Manager, manually run registration steps"
        return 2  # Return 2 to indicate skipped
    fi

# Combined Step: Cleanup, Register, and Validate in ONE run-command
if [[ "$SKIP_REGISTRATION" == true ]]; then
    vm_log "Executing VM configuration (cleanup only - registration skipped)..."
else
    vm_log "Executing VM configuration (cleanup, register, validate)..."
fi

if [[ "$SKIP_REGISTRATION" == true ]]; then
    # Skip registration mode - cleanup only, no SUSE Manager registration
    COMBINED_SCRIPT="
#!/bin/bash
set -e
echo '=== STEP 1: PAYG Cleanup ==='
# Stop and disable guestregister service
if systemctl list-units --type=service | grep -q guestregister; then
    systemctl stop guestregister.service 2>/dev/null || true
    systemctl disable guestregister.service 2>/dev/null || true
fi

# Backup and remove PAYG repos
if [ -d /etc/zypp/repos.d ]; then
    mkdir -p /etc/zypp/repos.d.backup
    cp /etc/zypp/repos.d/*.repo /etc/zypp/repos.d.backup/ 2>/dev/null || true
    rm -f /etc/zypp/repos.d/*.repo || true
fi

# Remove registration files
rm -rf /var/cache/cloudregister/* 2>/dev/null || true
rm -f /etc/regionserverclnt.cfg 2>/dev/null || true
echo 'Cleanup completed'

echo ''
echo '=== STEP 2: SUSE Manager Registration (SKIPPED) ==='
echo 'Registration skipped - use your own method (Ansible, Puppet, etc.)'
echo 'PAYG repos have been backed up to /etc/zypp/repos.d.backup/'

echo ''
echo '=== STEP 3: Validation ==='
echo 'Backup repos count:'
ls /etc/zypp/repos.d.backup/*.repo 2>/dev/null | wc -l
echo 'Current repos (should be empty):'
ls /etc/zypp/repos.d/*.repo 2>/dev/null | wc -l || echo '0'
"
elif [[ "$TEST_MODE" == true ]]; then
    # Test mode - combined script
    COMBINED_SCRIPT="
#!/bin/bash
set -e
echo '=== STEP 1: PAYG Cleanup ==='
# Stop and disable guestregister service
if systemctl list-units --type=service | grep -q guestregister; then
    systemctl stop guestregister.service 2>/dev/null || true
    systemctl disable guestregister.service 2>/dev/null || true
fi

# Backup and remove PAYG repos
if [ -d /etc/zypp/repos.d ]; then
    mkdir -p /etc/zypp/repos.d.backup
    cp /etc/zypp/repos.d/*.repo /etc/zypp/repos.d.backup/ 2>/dev/null || true
    rm -f /etc/zypp/repos.d/*.repo || true
fi

# Remove registration files
rm -rf /var/cache/cloudregister/* 2>/dev/null || true
rm -f /etc/regionserverclnt.cfg 2>/dev/null || true
echo 'Cleanup completed'

echo ''
echo '=== STEP 2: SUSE Manager Registration (TEST MODE) ==='
mkdir -p /etc/zypp/repos.d
cat > /etc/zypp/repos.d/TEST-SUSE-Manager.repo << 'EOFR'
[TEST-SUSE-Manager]
name=TEST SUSE Manager Repository (simulated)
enabled=1
autorefresh=1
baseurl=https://${SUSE_MANAGER_URL}/test
type=rpm-md
EOFR
echo 'Test repository created'

echo ''
echo '=== STEP 3: Validation ==='
echo 'Repository Configuration:'
zypper lr -u
echo ''
echo 'Active Repositories:'
zypper repos --uri | grep -E '(Enabled|URI)'
"
else
    # Production mode - combined script
    COMBINED_SCRIPT="
#!/bin/bash
set -e
echo '=== STEP 1: PAYG Cleanup ==='
# Stop and disable guestregister service
if systemctl list-units --type=service | grep -q guestregister; then
    systemctl stop guestregister.service 2>/dev/null || true
    systemctl disable guestregister.service 2>/dev/null || true
fi

# Backup and remove PAYG repos
if [ -d /etc/zypp/repos.d ]; then
    mkdir -p /etc/zypp/repos.d.backup
    cp /etc/zypp/repos.d/*.repo /etc/zypp/repos.d.backup/ 2>/dev/null || true
    rm -f /etc/zypp/repos.d/*.repo || true
fi

# Remove registration files
rm -rf /var/cache/cloudregister/* 2>/dev/null || true
rm -f /etc/regionserverclnt.cfg 2>/dev/null || true
echo 'Cleanup completed'

echo ''
echo '=== STEP 2: SUSE Manager Registration ==='
"
    if [[ -n "$ACTIVATION_KEY" ]]; then
        COMBINED_SCRIPT+="curl -Sks https://${SUSE_MANAGER_URL}/pub/bootstrap/bootstrap.sh | bash -s -- -a ${ACTIVATION_KEY}
"
    else
        COMBINED_SCRIPT+="curl -Sks https://${SUSE_MANAGER_URL}/pub/bootstrap/bootstrap.sh | bash
"
    fi
    
    COMBINED_SCRIPT+="
echo ''
echo '=== STEP 3: Validation ==='
echo 'Repository Configuration:'
zypper lr -u
echo ''
if command -v rhn_check &> /dev/null; then
    echo 'SUSE Manager Registration Status:'
    rhn_check
fi
echo ''
echo 'Active Repositories:'
zypper repos --uri | grep -E '(Enabled|URI)'
"
fi

vm_log "Running combined cleanup/register/validate script..."
echo -n "  [VM Config] Executing"

{
    COMBINED_OUTPUT=$(az vm run-command invoke \
        -g "$RESOURCE_GROUP" \
        -n "$CURRENT_VM" \
        --command-id RunShellScript \
        --scripts "$COMBINED_SCRIPT" \
        --output json 2>&1)
    echo "$COMBINED_OUTPUT" > /tmp/combined_output_$CURRENT_VM
} &
COMBINED_PID=$!

while kill -0 $COMBINED_PID 2>/dev/null; do
    echo -n "."
    sleep 3
done
wait $COMBINED_PID
echo " Done"

COMBINED_OUTPUT=$(cat /tmp/combined_output_$CURRENT_VM)
rm -f /tmp/combined_output_$CURRENT_VM

# Extract and display validation results
vm_log "=== VM Configuration Results ==="
# Parse the stdout message from JSON and log it properly
STDOUT_MESSAGE=$(echo "$COMBINED_OUTPUT" | jq -r '.value[0].message' 2>/dev/null | sed -n '/\[stdout\]/,/\[stderr\]/p' | sed '1d;$d')
if [[ -n "$STDOUT_MESSAGE" ]]; then
    echo "$STDOUT_MESSAGE" | while IFS= read -r line; do
        vm_log "$line"
    done
else
    # Fallback if jq parsing fails
    vm_log "Failed to parse VM output, showing raw output:"
    echo "$COMBINED_OUTPUT" | while IFS= read -r line; do
        vm_log "$line"
    done
fi
vm_log "Configuration completed"

# Step 2: Update Azure license type
vm_log "Step 2: Updating Azure license type to SLES_BYOS..."
echo -n "  [License] Updating"

{
    LICENSE_UPDATE_OUTPUT=$(az vm update \
        -g "$RESOURCE_GROUP" \
        -n "$CURRENT_VM" \
        --license-type SLES_BYOS 2>&1)
    echo "$LICENSE_UPDATE_OUTPUT" > /tmp/license_output_$CURRENT_VM
} &
LIC_PID=$!

while kill -0 $LIC_PID 2>/dev/null; do
    echo -n "."
    sleep 3
done
wait $LIC_PID
echo " Done"

LICENSE_UPDATE_OUTPUT=$(cat /tmp/license_output_$CURRENT_VM)
rm -f /tmp/license_output_$CURRENT_VM

vm_log "License type updated successfully"

# Step 3: Verify Azure license type
vm_log "Step 3: Verifying Azure license type..."
echo -n "  [License Check] Verifying"

{
    NEW_LICENSE=$(az vm show -g "$RESOURCE_GROUP" -n "$CURRENT_VM" --query licenseType -o tsv 2>&1 | tr -d '\r\n')
    echo "$NEW_LICENSE" > /tmp/license_check_$CURRENT_VM
} &
LIC_CHK_PID=$!

while kill -0 $LIC_CHK_PID 2>/dev/null; do
    echo -n "."
    sleep 3
done
wait $LIC_CHK_PID
echo " Done"

NEW_LICENSE=$(cat /tmp/license_check_$CURRENT_VM)
rm -f /tmp/license_check_$CURRENT_VM
if [[ "$NEW_LICENSE" == "SLES_BYOS" ]]; then
    vm_log "✓ Azure license type confirmed: SLES_BYOS"
else
    vm_log "⚠ License type is: $NEW_LICENSE (expected SLES_BYOS)"
fi

# VM Summary
vm_log "VM Conversion Summary:"
vm_log "  VM Name: $CURRENT_VM"
vm_log "  Previous License: $CURRENT_LICENSE"
vm_log "  New License: $NEW_LICENSE"
vm_log "✓ VM $CURRENT_VM conversion completed successfully!"
return 0
}

# Process all VMs
TOTAL_VMS=${#VMS[@]}
SUCCESSFUL=0
FAILED=0
SKIPPED=0

# Create temporary directory for job tracking
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

if [[ $PARALLEL_JOBS -eq 1 ]]; then
    # Sequential execution
    for i in "${!VMS[@]}"; do
        VM_NUMBER=$((i + 1))
        
        convert_vm "${VMS[$i]}" "$VM_NUMBER" "$TOTAL_VMS"
        EXIT_CODE=$?
        
        if [ $EXIT_CODE -eq 0 ]; then
            ((SUCCESSFUL++))
        elif [ $EXIT_CODE -eq 2 ]; then
            ((SKIPPED++))
            log_info "⊙ Skipped VM (already BYOS): ${VMS[$i]}"
        else
            ((FAILED++))
            log_error "✗ Failed to convert VM: ${VMS[$i]}"
        fi
        
        # Add delay between VMs if processing multiple
        if [[ $TOTAL_VMS -gt 1 && $VM_NUMBER -lt $TOTAL_VMS ]]; then
            log_info "Waiting 10 seconds before processing next VM..."
            sleep 10
        fi
    done
else
    # Parallel execution
    for i in "${!VMS[@]}"; do
        VM_NUMBER=$((i + 1))
        
        # Wait if we've reached max parallel jobs
        while [ $(jobs -r | wc -l) -ge $PARALLEL_JOBS ]; do
            sleep 2
        done
        
        # Run conversion in background
        (
            convert_vm "${VMS[$i]}" "$VM_NUMBER" "$TOTAL_VMS"
            echo $? > "$TEMP_DIR/${VMS[$i]}.status"
        ) &
        
        log_info "Started job for VM: ${VMS[$i]} (PID: $!)"
    done
    
    # Wait for all background jobs to complete
    log_info "Waiting for all conversion jobs to complete..."
    wait
    
    # Collect results
    for vm in "${VMS[@]}"; do
        if [ -f "$TEMP_DIR/$vm.status" ]; then
            EXIT_CODE=$(cat "$TEMP_DIR/$vm.status")
            if [ $EXIT_CODE -eq 0 ]; then
                ((SUCCESSFUL++))
            elif [ $EXIT_CODE -eq 2 ]; then
                ((SKIPPED++))
                log_info "⊙ Skipped VM (already BYOS): $vm"
            else
                ((FAILED++))
                log_error "✗ Failed to convert VM: $vm"
            fi
        else
            ((FAILED++))
            log_error "✗ No status file found for VM: $vm"
        fi
    done
fi

# Post-conversion validation: Check repositories on all BYOS VMs (parallel)
if [[ $SUCCESSFUL -gt 0 || $SKIPPED -gt 0 ]]; then
    echo ""
    log_info "=========================================="
    if [[ "$SKIP_REGISTRATION" == true ]]; then
        log_info "Post-Conversion Cleanup Validation"
    else
        log_info "Post-Conversion Repository Validation"
    fi
    log_info "=========================================="
    
    # Run validation checks in parallel
    for vm in "${VMS[@]}"; do
        (
            # Check if VM is BYOS
            LICENSE=$(az vm show -g "$RESOURCE_GROUP" -n "$vm" --query licenseType -o tsv 2>&1 | tr -d '\r\n')
            if [[ "$LICENSE" == "SLES_BYOS" ]]; then
                if [[ "$SKIP_REGISTRATION" == true ]]; then
                    # For skip-registration mode, check that repos are removed and backup exists
                    CLEANUP_CHECK=$(az vm run-command invoke \
                        -g "$RESOURCE_GROUP" \
                        -n "$vm" \
                        --command-id RunShellScript \
                        --scripts "echo 'Current repos:' && ls /etc/zypp/repos.d/*.repo 2>/dev/null | wc -l && echo 'Backup repos:' && ls /etc/zypp/repos.d.backup/*.repo 2>/dev/null | wc -l" \
                        --query 'value[0].message' -o tsv 2>&1)
                    
                    CURRENT_COUNT=$(echo "$CLEANUP_CHECK" | grep -A1 "Current repos:" | tail -1 | tr -d '[:space:]')
                    BACKUP_COUNT=$(echo "$CLEANUP_CHECK" | grep -A1 "Backup repos:" | tail -1 | tr -d '[:space:]')
                    
                    if [[ "$CURRENT_COUNT" == "0" && "$BACKUP_COUNT" -gt 0 ]]; then
                        echo "✓|$vm|Cleanup complete - $BACKUP_COUNT repos backed up, ready for registration"
                    elif [[ "$CURRENT_COUNT" == "0" ]]; then
                        echo "✓|$vm|Cleanup complete - repos removed"
                    else
                        echo "⚠|$vm|Cleanup may be incomplete - $CURRENT_COUNT repos remain"
                    fi
                else
                    REPO_CHECK=$(az vm run-command invoke \
                        -g "$RESOURCE_GROUP" \
                        -n "$vm" \
                        --command-id RunShellScript \
                        --scripts "zypper lr -u 2>/dev/null || echo 'No repositories found'" \
                        --query 'value[0].message' -o tsv 2>&1)
                    
                    if [[ "$TEST_MODE" == true ]]; then
                        if echo "$REPO_CHECK" | grep -q "TEST-SUSE-Manager"; then
                            echo "✓|$vm|Test repository configured"
                        else
                            echo "⚠|$vm|Test repository not found"
                        fi
                    else
                        if echo "$REPO_CHECK" | grep -qi "suse.*manager\|rmt\|smt"; then
                            echo "✓|$vm|SUSE Manager repository detected"
                        else
                            echo "⚠|$vm|No SUSE Manager repository found - please verify manually"
                        fi
                    fi
                fi
            fi
        ) > "$TEMP_DIR/validation_$vm.txt" &
    done
    
    # Wait for all validation checks to complete
    wait
    
    # Display results in order
    for vm in "${VMS[@]}"; do
        if [ -f "$TEMP_DIR/validation_$vm.txt" ]; then
            RESULT=$(cat "$TEMP_DIR/validation_$vm.txt")
            if [[ -n "$RESULT" ]]; then
                STATUS=$(echo "$RESULT" | cut -d'|' -f1)
                VM_NAME=$(echo "$RESULT" | cut -d'|' -f2)
                MESSAGE=$(echo "$RESULT" | cut -d'|' -f3)
                
                log_info "Checking repositories on VM: $VM_NAME"
                if [[ "$STATUS" == "✓" ]]; then
                    log_info "  ✓ $VM_NAME: $MESSAGE"
                else
                    log_warn "  ⚠ $VM_NAME: $MESSAGE"
                fi
            fi
        fi
    done
    echo ""
fi

# Final Summary
echo ""
log_info "=========================================="
log_info "Final Conversion Summary"
log_info "=========================================="
log_info "Resource Group: $RESOURCE_GROUP"
log_info "Execution Mode: $([ $PARALLEL_JOBS -eq 1 ] && echo 'Sequential' || echo "Parallel ($PARALLEL_JOBS jobs)")"
log_info "Total VMs Found: $TOTAL_VMS"
log_info "Successful: $SUCCESSFUL"
log_info "Skipped (already BYOS): $SKIPPED"
log_info "Failed: $FAILED"
if [[ "$SKIP_REGISTRATION" == true ]]; then
    log_info "SUSE Manager: N/A (skip-registration mode)"
else
    log_info "SUSE Manager: $SUSE_MANAGER_URL"
fi
log_info "=========================================="
echo ""
log_info "Log file: $LOG_FILE"
log_warn "Next steps:"
echo "  1. Review the log file for any errors"
if [[ "$SKIP_REGISTRATION" == true ]]; then
    echo "  2. Run your SUSE Manager registration (Ansible playbook, etc.)"
    echo "  3. Verify SUSE Manager repos are configured on VMs"
    echo "  4. Test application functionality on converted VMs"
else
    echo "  2. Test application functionality on converted VMs"
fi
log_to_file "Batch conversion completed - $SUCCESSFUL successful, $SKIPPED skipped, $FAILED failed"
