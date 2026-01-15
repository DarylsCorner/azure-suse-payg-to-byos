# SUSE PAYG to BYOS Conversion Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.0+-green.svg)](https://www.gnu.org/software/bash/)
[![Azure CLI](https://img.shields.io/badge/Azure_CLI-Required-blue.svg)](https://docs.microsoft.com/en-us/cli/azure/)
![GitHub last commit](https://img.shields.io/github/last-commit/DarylsCorner/azure-suse-payg-to-byos)
![GitHub issues](https://img.shields.io/github/issues/DarylsCorner/azure-suse-payg-to-byos)
[![Azure](https://img.shields.io/badge/Azure-Compatible-0078D4?logo=microsoft-azure)](https://azure.microsoft.com)
[![SUSE](https://img.shields.io/badge/SUSE-Linux-0C322C?logo=suse)](https://www.suse.com)

This script automates the conversion of Azure SUSE VMs from Pay-As-You-Go (PAYG) to Bring-Your-Own-Subscription (BYOS) with SUSE Manager registration.

## Prerequisites

- Linux management VM with bash
- Azure CLI installed and authenticated (`az login`)
- Network access to the target VM and SUSE Manager
- Appropriate Azure permissions to modify VMs
- SUSE Manager server configured and accessible
- **Activation key stored securely** (Key Vault or environment variable)

## Security Features

🔒 **Secure Activation Key Handling:**
- No command-line parameters for activation keys (prevents exposure in process lists and bash history)
- Supports Azure Key Vault integration (recommended for production)
- Supports environment variables (convenient for development)
- URL validation prevents injection attacks

## Quick Start

### 1. Store Activation Key Securely

**Production (Key Vault - Recommended):**
```bash
# One-time setup: Store key in Key Vault
az keyvault secret set \
  --vault-name "WorkloadKeyVault" \
  --name "suse-activation-key" \
  --value "your-actual-activation-key"

# Grant yourself access (if needed)
az keyvault set-policy \
  --name "WorkloadKeyVault" \
  --upn "your-email@company.com" \
  --secret-permissions get list
```

**Development (Environment Variable):**
```bash
export SUSE_ACTIVATION_KEY="your-dev-activation-key"
```

### 2. Make Script Executable
```bash
chmod +x convert-suse-payg-to-byos.sh
```

### 3. Test on a Single VM
```bash
# Using Key Vault
./convert-suse-payg-to-byos.sh \
  -g <resource-group> \
  -n <vm-name> \
  -s <suse-manager-url> \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key

# Using environment variable
./convert-suse-payg-to-byos.sh \
  -g <resource-group> \
  -n <vm-name> \
  -s <suse-manager-url>
```

### 4. Convert All SLES VMs in Resource Group
```bash
./convert-suse-payg-to-byos.sh \
  -g <resource-group> \
  -s <suse-manager-url> \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-g` | Yes | Azure resource group name |
| `-s` | Yes* | SUSE Manager server URL (e.g., suse-manager.example.com) |
| `--keyvault` | No* | Azure Key Vault name containing activation key |
| `--secret-name` | No* | Secret name in Key Vault (use with --keyvault) |
| `--skip-registration` | No | Skip SUSE Manager registration (cleanup and license change only) |
| `-n` | No | VM name (if omitted, converts ALL SLES VMs in resource group) |
| `-p` | No | Number of parallel jobs (default: 1 for sequential). Recommended: 5-10 |
| `-t` | No | Test mode - skips SUSE Manager registration |
| `-y` | No | Auto-confirm (skip confirmation prompt) |
| `-h` | No | Display help message |

**Notes:**
- Either `--keyvault`/`--secret-name` OR environment variable `SUSE_ACTIVATION_KEY` must be set (unless using `-t` test mode or `--skip-registration`)
- `-s` is required unless using `--skip-registration`

## What the Script Does

For each VM:
1. **Check existing license**: Skips VMs already configured with SLES_BYOS
2. **Cleanup PAYG Registration**: Removes SUSE Public Cloud registration and PAYG repositories
3. **Register to SUSE Manager**: Installs bootstrap script and registers VM to your SUSE Manager
   - *Or skipped if using `--skip-registration` (for external registration methods)*
4. **Update Azure License**: Changes the Azure license type to `SLES_BYOS`
5. **Validate Configuration**: Verifies repository configuration and license type

### Repository Management Details

**⚠️ IMPORTANT: The script removes ALL repositories during cleanup**

During the cleanup phase, the script:
1. **Backs up all existing repos** to `/etc/zypp/repos.d.backup/` on each VM
2. **Removes ALL `.repo` files** from `/etc/zypp/repos.d/`
3. **Registers to SUSE Manager** which adds new repository configurations

**What gets removed:**
- PAYG SUSE repositories (intended target)
- Any custom/third-party repositories you may have added
- Additional SUSE module repositories

**Why this approach:**
- Ensures clean transition from PAYG to BYOS
- Prevents conflicts between PAYG and SUSE Manager repos
- SUSE Manager bootstrap adds all necessary repos based on your configuration

**If you have custom repositories:**
1. Review backed up repos after conversion: `ls /etc/zypp/repos.d.backup/`
2. Manually restore non-SUSE repos if needed
3. Consider adding custom repos to your SUSE Manager configuration instead

**Example of what's preserved in backup:**
```bash
# SSH to VM after conversion
ls -la /etc/zypp/repos.d.backup/
# Output shows original repos:
# SLES_SAP-15-SP6-Updates.repo
# SLES_SAP-15-SP6-Pool.repo
# custom-app.repo  <- Your custom repo backed up here
```

**Cleaning up backups:**
Once you've verified the conversion was successful and no longer need the backed-up repositories, use the cleanup script:
```bash
# Clean up single VM
./cleanup-backup-repos.sh -g prod-sap-rg -n sap-vm-01

# Clean up all SLES VMs in resource group
./cleanup-backup-repos.sh -g prod-sap-rg -y
```

## Important Notes

- **No image change required**: The script works with your existing `sles-sap-15-sp6` image
- **Idempotent**: Safely skips VMs already configured with BYOS license
- **Test mode**: Use `-t` flag to test script logic without SUSE Manager (validates everything except registration)
  - Can be combined with Key Vault parameters to verify activation key retrieval
  - Logs the first 20 characters of retrieved key for verification
  - Creates test repository instead of real SUSE Manager registration
- **Single VM or resource group mode**: Use `-n` for testing one VM, omit it to process all SLES VMs
- **Auto-discovery**: When processing a resource group, automatically finds all SLES VMs
- **Parallel execution**: Use `-p` flag to run multiple conversions simultaneously (recommended: 5-10)
- **Minimal downtime**: Most operations don't require VM restart
- **Reversible**: Keep backups of repository configurations (auto-saved to `/etc/zypp/repos.d.backup/`)
- **Detailed logging**: Main log file + individual per-VM log files for easy troubleshooting
- **Skip registration mode**: Use `--skip-registration` for external registration methods (Ansible, Puppet, Chef, etc.)

## Skip Registration Mode

Use `--skip-registration` when you have your own method for SUSE Manager registration (e.g., Ansible playbook, Puppet, Chef, or other configuration management tools).

**What it does:**
1. Cleans up PAYG registration and repos (with backup)
2. Changes Azure license type to SLES_BYOS
3. Validates cleanup was successful
4. **Skips** SUSE Manager bootstrap script

**Use case:** Your organization uses Ansible or another tool to register systems with SUSE Manager. This script handles the Azure-side conversion while your existing automation handles the SUSE registration.

```bash
# Run cleanup and license change only - register with your own method afterward
./convert-suse-payg-to-byos.sh \
  -g prod-sap-rg \
  --skip-registration \
  -p 5 \
  -y

# Then run your Ansible playbook to register with SUSE Manager
ansible-playbook -i inventory suse-manager-register.yml
```

**Validation output in skip-registration mode:**
- Shows how many repos were backed up (e.g., "70 repos backed up")
- Confirms current repos directory is empty (ready for registration)

## Example Usage

```bash
# Test mode - validate script without SUSE Manager (no activation key needed)
./convert-suse-payg-to-byos.sh \
  -g test-rg \
  -s test.example.com \
  -t

# Test mode with Key Vault - validates activation key retrieval (recommended for pre-deployment testing)
./convert-suse-payg-to-byos.sh \
  -g test-rg \
  -n test-vm-01 \
  -s test.example.com \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key \
  -t

# Production: Test on single VM with Key Vault (recommended)
./convert-suse-payg-to-byos.sh \
  -g prod-sap-rg \
  -n sap-vm-01 \
  -s suse-manager.company.com \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key

# Production: Convert all SLES VMs with Key Vault (sequential)
./convert-suse-payg-to-byos.sh \
  -g prod-sap-rg \
  -s suse-manager.company.com \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key

# Production: Convert all SLES VMs with Key Vault (3 parallel jobs)
./convert-suse-payg-to-byos.sh \
  -g prod-sap-rg \
  -s suse-manager.company.com \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key \
  -p 3

# Development: Using environment variable
export SUSE_ACTIVATION_KEY="dev-key-12345"
./convert-suse-payg-to-byos.sh \
  -g dev-rg \
  -s suse-manager-dev.company.com

# Skip registration - use when you have your own registration method (Ansible, Puppet, etc.)
./convert-suse-payg-to-byos.sh \
  -g prod-sap-rg \
  --skip-registration \
  -p 5 \
  -y
```

## Post-Conversion Validation

After running the script, verify:

1. **Repositories point to SUSE Manager**:
   ```bash
   az vm run-command invoke -g <rg> -n <vm> \
     --command-id RunShellScript \
     --scripts "zypper lr -u"
   ```

2. **License type is SLES_BYOS**:
   ```bash
   az vm show -g <rg> -n <vm> --query licenseType
   ```

3. **SUSE Manager registration is active**:
   ```bash
   az vm run-command invoke -g <rg> -n <vm> \
     --command-id RunShellScript \
     --scripts "rhn_check"
   ```

4. **Clean up backup repositories** (optional, after successful validation):
   ```bash
   # Remove backed-up PAYG repos from single VM
   ./cleanup-backup-repos.sh -g <rg> -n <vm>
   
   # Remove backed-up PAYG repos from all VMs in resource group
      # Remove backed-up PAYG repos from all VMs in resource group
   ./cleanup-backup-repos.sh -g <rg> -y
   ```

## Log File Structure

The script creates a dedicated directory for each run to keep all related log files organized:

```
logs/
└── RG-EastUS_20251117-165702/
    ├── main.log                        # Main summary log with all VM operations
    ├── sles-payg-vmss_42a53c95.log    # Individual VM log
    ├── sles-payg-vmss_46d5850d.log    # Individual VM log
    └── sles-payg-vmss_7b20ceeb.log    # Individual VM log
```

**Benefits:**
- **Easy to find**: All logs for a specific run are in one directory
- **Clean separation**: Each run is isolated, preventing hundreds of log files mixed together
- **Simple review**: Check `main.log` for overview, individual VM logs for detailed troubleshooting
- **Directory naming**: `<ResourceGroup>_<Timestamp>` format makes it easy to identify runs

**Viewing logs:**
```bash
# View main summary log
cat logs/RG-EastUS_20251117-165702/main.log

# View specific VM log (no VM prefix clutter)
cat logs/RG-EastUS_20251117-165702/sles-payg-vmss_42a53c95.log

# Filter main log for specific VM
grep "\[VM: sles-payg-vmss_42a53c95\]" logs/RG-EastUS_20251117-165702/main.log

# List all log directories
ls -lt logs/
```

## Troubleshooting
   ```

## Workflow

### Phase 0: Pre-Deployment Testing (Recommended)
```bash
# Test Key Vault access without touching production SUSE Manager
./convert-suse-payg-to-byos.sh \
  -g test-rg \
  -n test-vm-01 \
  -s test.example.com \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key \
  -t -y
```
- Validates Key Vault access and activation key retrieval
- Tests VM cleanup and license change without SUSE Manager
- Logs show: `TEST MODE - Retrieved activation key: <first-20-chars>... (<length> chars)`
- Safe to run in any environment

### Phase 1: Test on Single VM
```bash
./convert-suse-payg-to-byos.sh \
  -g prod-sap-rg \
  -n sap-vm-01 \
  -s suse-manager.company.com \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key
```
- Validates the process on one VM with real SUSE Manager
- Allows you to verify repository configuration
- Test application functionality before scaling

### Phase 2: Convert Entire Resource Group

**Sequential (safe, slower):**
```bash
./convert-suse-payg-to-byos.sh \
  -g prod-sap-rg \
  -s suse-manager.company.com \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key
```
- Processes VMs one at a time
- Easier to troubleshoot
- Best for initial rollout

**Parallel (faster, more load):**
```bash
./convert-suse-payg-to-byos.sh \
  -g prod-sap-rg \
  -s suse-manager.company.com \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key \
  -p 3
```
- Processes 3 VMs simultaneously
- 3-5x faster for large deployments
- Creates individual log files per VM
- Monitor SUSE Manager load

## Troubleshooting

### Script fails at cleanup step
- Check VM is running: `az vm show -g <rg> -n <vm> --query powerState`
- Verify network connectivity to VM

### SUSE Manager registration fails
- Verify SUSE Manager URL is accessible from VM
- Check activation key retrieval (Key Vault access or environment variable set)
- Verify Key Vault permissions: `az keyvault secret show --vault-name <vault> --name <secret>`
- Ensure bootstrap script exists at `https://<suse-manager>/pub/bootstrap/bootstrap.sh`
- Monitor SUSE Manager load if running parallel jobs

### Activation key errors
- **Key Vault access denied**: 
  - For users: Ensure you have `Key Vault Secrets User` role or access policy
  - For UAMI: Grant access policy with `az keyvault set-policy --object-id <uami-object-id>`
  - For Service Principal: Grant access policy with object ID
  - Verify authentication: `az account show`
- **Environment variable not set**: Check `echo $SUSE_ACTIVATION_KEY`
- **Invalid URL format**: Script validates URL - check error message for details
- **UAMI not authenticated**: 
  - Login with: `az login --identity --client-id <uami-client-id>` (note: use --client-id, not --username)
  - Verify UAMI is assigned to the VM running the script
  - Ensure UAMI has subscription Reader role assigned

### License type doesn't update
- Verify you have permissions: `az vm update` requires VM Contributor role
- Check Azure Resource Provider is registered

### Parallel execution issues
- Reduce `-p` value if seeing timeouts or rate limiting
- Check Azure CLI rate limits: `az account show --query tenantId`
- Monitor SUSE Manager server resources during parallel operations
- Review individual VM log files in `logs/` directory

### VMs already BYOS being skipped
- This is expected behavior (idempotent)
- Script only converts VMs not already marked as SLES_BYOS
- To force re-registration, manually reset license and re-run

## Security Best Practices

### Activation Key Storage

**✅ Recommended: Azure Key Vault**
- Keys encrypted at rest and in transit
- Access controlled via Azure RBAC
- Audit logs for all access
- Supports key rotation

**Setup:**
```bash
# Store activation key
az keyvault secret set \
  --vault-name "WorkloadKeyVault" \
  --name "suse-activation-key" \
  --value "your-key-here"

# === Option 1: Access Policies (Traditional) ===

# Grant access to users
az keyvault set-policy \
  --name "WorkloadKeyVault" \
  --upn "user@company.com" \
  --secret-permissions get list

# Grant access to User-Assigned Managed Identity (UAMI)
az keyvault set-policy \
  --name "WorkloadKeyVault" \
  --object-id "<uami-object-id>" \
  --secret-permissions get list

# Grant access to Service Principal
az keyvault set-policy \
  --name "WorkloadKeyVault" \
  --object-id "<sp-object-id>" \
  --secret-permissions get list
```

```bash
# === Option 2: Azure RBAC (Recommended for new Key Vaults) ===

# Create Key Vault with RBAC enabled
az keyvault create \
  --name "WorkloadKeyVault" \
  --resource-group "<resource-group>" \
  --enable-rbac-authorization true

# Grant "Key Vault Secrets User" role to users
az role assignment create \
  --assignee "user@company.com" \
  --role "Key Vault Secrets User" \
  --scope "/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/WorkloadKeyVault"

# Grant "Key Vault Secrets User" role to UAMI
az role assignment create \
  --assignee "<uami-object-id>" \
  --role "Key Vault Secrets User" \
  --scope "/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/WorkloadKeyVault"

# Grant "Key Vault Secrets User" role to Service Principal
az role assignment create \
  --assignee "<sp-object-id>" \
  --role "Key Vault Secrets User" \
  --scope "/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/WorkloadKeyVault"
```

**Note:** The script works with both Access Policies and RBAC - use whichever your organization prefers.


**Using with Managed Identity:**
If running the script from a VM with User-Assigned Managed Identity (UAMI):
1. Ensure the VM has the UAMI assigned
2. Grant the UAMI **two required permissions**:
   - Key Vault access policy for secrets (see above)
   - Subscription Reader role: `az role assignment create --assignee <uami-principal-id> --role Reader --scope /subscriptions/<subscription-id>`
3. Authenticate Azure CLI with the managed identity:
   ```bash
   # Login with UAMI (use --client-id, not --username)
   az login --identity --client-id <uami-client-id>
   
   # Verify authentication (should show type: servicePrincipal)
   az account show
   ```
4. Run the script normally - it will use the UAMI's permissions

**✅ Tested:** UAMI Key Vault access has been validated in test environment

**⚠️ Acceptable: Environment Variable**
- Use for development/testing only
- Set in secure shell sessions
- Never commit to version control
- Clear after use: `unset SUSE_ACTIVATION_KEY`

**❌ NOT Supported: Command Line Parameter**
- Previous `-k` parameter has been removed
- Command-line parameters visible in process lists and bash history
- Use Key Vault or environment variables instead

### Activation Key Retrieval

**How it works:**
- Activation key is retrieved **once** at script startup from Key Vault or environment variable
- The same key is reused for all VMs in the batch (no per-VM retrieval)
- VMs never access Key Vault directly - they receive the key via the bootstrap command
- In test mode (`-t`), logs show first 20 characters of retrieved key for verification

**Testing Key Vault access:**
```bash
# Verify Key Vault retrieval works before production use
./convert-suse-payg-to-byos.sh -g <rg> -n <vm> -s test.example.com \
  --keyvault WorkloadKeyVault --secret-name suse-activation-key -t
```

### URL Validation

The script automatically validates SUSE Manager URLs to prevent injection attacks:
- Only alphanumeric characters, dots, and hyphens allowed
- Dangerous characters (`;`, `&`, `|`, `` ` ``, `$`, etc.) are rejected
- Must be valid hostname format

### Known Limitations

**Azure Activity Logs:**
- Activation keys retrieved from Key Vault may appear in Azure activity logs
- Keys are encrypted in transit but visible to Azure administrators
- **Mitigation**: Use limited-scope activation keys, rotate regularly

**VM Run-Command Logs:**
- Bootstrap scripts may log activation key usage
- **Mitigation**: Enable SUSE Manager logging controls, limit key scope

## Support

For issues specific to:
- **Azure operations**: Check Azure CLI output and subscription permissions
- **SUSE Manager**: Verify server configuration, activation keys, and server load
- **VM connectivity**: Ensure VM is running and network rules allow management traffic
- **Parallel execution**: Review individual VM logs, reduce parallelism if issues occur
- **Security**: Review Key Vault access policies and audit logs
