# SUSE PAYG to BYOS Conversion Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.0+-green.svg)](https://www.gnu.org/software/bash/)
[![Azure CLI](https://img.shields.io/badge/Azure_CLI-Required-blue.svg)](https://docs.microsoft.com/en-us/cli/azure/)

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
| `-s` | Yes | SUSE Manager server URL (e.g., suse-manager.example.com) |
| `--keyvault` | No* | Azure Key Vault name containing activation key |
| `--secret-name` | No* | Secret name in Key Vault (use with --keyvault) |
| `-n` | No | VM name (if omitted, converts ALL SLES VMs in resource group) |
| `-p` | No | Number of parallel jobs (default: 1 for sequential). Recommended: 5-10 |
| `-t` | No | Test mode - skips SUSE Manager registration |
| `-y` | No | Auto-confirm (skip confirmation prompt) |
| `-h` | No | Display help message |

**Note:** Either `--keyvault`/`--secret-name` OR environment variable `SUSE_ACTIVATION_KEY` must be set (unless using `-t` test mode)

## What the Script Does

For each VM:
1. **Check existing license**: Skips VMs already configured with SLES_BYOS
2. **Cleanup PAYG Registration**: Removes SUSE Public Cloud registration and PAYG repositories
3. **Register to SUSE Manager**: Installs bootstrap script and registers VM to your SUSE Manager
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

## Important Notes

- **No image change required**: The script works with your existing `sles-sap-15-sp6` image
- **Idempotent**: Safely skips VMs already configured with BYOS license
- **Test mode**: Use `-t` flag to test script logic without SUSE Manager (validates everything except registration)
- **Single VM or resource group mode**: Use `-n` for testing one VM, omit it to process all SLES VMs
- **Auto-discovery**: When processing a resource group, automatically finds all SLES VMs
- **Parallel execution**: Use `-p` flag to run multiple conversions simultaneously (recommended: 5-10)
- **Minimal downtime**: Most operations don't require VM restart
- **Reversible**: Keep backups of repository configurations (auto-saved to `/etc/zypp/repos.d.backup/`)
- **Detailed logging**: Main log + individual VM logs for parallel execution

## Example Usage

```bash
# Test mode - validate script without SUSE Manager (no activation key needed)
./convert-suse-payg-to-byos.sh \
  -g test-rg \
  -s test.example.com \
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

## Workflow

### Phase 1: Test on Single VM
```bash
./convert-suse-payg-to-byos.sh \
  -g prod-sap-rg \
  -n sap-vm-01 \
  -s suse-manager.company.com \
  --keyvault WorkloadKeyVault \
  --secret-name suse-activation-key
```
- Validates the process on one VM
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
- **Key Vault access denied**: Ensure you have `Key Vault Secrets User` role
- **Environment variable not set**: Check `echo $SUSE_ACTIVATION_KEY`
- **Invalid URL format**: Script validates URL - check error message for details

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

# Grant access to users/service principals
az keyvault set-policy \
  --name "WorkloadKeyVault" \
  --upn "user@company.com" \
  --secret-permissions get list
```

**⚠️ Acceptable: Environment Variable**
- Use for development/testing only
- Set in secure shell sessions
- Never commit to version control
- Clear after use: `unset SUSE_ACTIVATION_KEY`

**❌ NOT Supported: Command Line Parameter**
- Previous `-k` parameter has been removed
- Command-line parameters visible in process lists and bash history
- Use Key Vault or environment variables instead

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
