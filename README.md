# Nutanix OVA Backup & Restore Tool

Interactive scripts for backing up and restoring VMs from Nutanix Prism Central.

## Table of Contents

- [Scripts Overview](#scripts-overview)
- [Workflow](#workflow)
- [Quick Start](#quick-start)
- [Usage Examples](#usage-examples)
- [Output Structure](#output-structure)
- [Navigation Commands](#navigation-commands)
- [Configuration](#configuration)
- [API Integration](#api-integration)
- [Security Notes](#security-notes)
- [Troubleshooting](#troubleshooting)

## Scripts Overview

| Script | Purpose | Best For |
|--------|---------|----------|
| **`scripts/setup_wizard.sh`** | Interactive setup and credential configuration | Initial setup, troubleshooting |
| **`scripts/export_menu.sh`** | Export VMs to OVA backups | Regular backups, migration prep |
| **`scripts/restore_menu.sh`** | Bulk restore multiple VMs | Disaster recovery, environment restore |
| **`scripts/custom_restore.sh`** | Single VM restore with custom settings | Selective recovery, cross-project moves |
| **`scripts/manage_restore_points.sh`** | Manage backup restore points | Cleanup, storage management, audit |

## Workflow

```
Setup: Run setup_wizard.sh → Configure credentials → Test connection
Export: VM Selection → Export → Download → Cleanup
Bulk Restore: Backup Selection → VM Selection → Upload → Restore  
Custom Restore: VM Selection → Restore Point → Configure → Upload → Restore
Management: View Restore Points → Delete/Statistics → Cleanup
```

## Quick Start

### Prerequisites
- Unix-like operating system (Linux, macOS, or WSL on Windows)
- `jq`, `curl`, `openssl`, and `base64` installed
- Network access to Nutanix Prism Central
- Valid Nutanix credentials
- Bash 4.0 or higher

### Setup
```bash
# 1. Make scripts executable
chmod +x scripts/*.sh

# 2. Run setup wizard (recommended)
./scripts/setup_wizard.sh

# OR quick setup (non-interactive)
./scripts/setup_wizard.sh --quick

# 3. Run desired script
./scripts/export_menu.sh         # Export VMs
./scripts/restore_menu.sh        # Bulk restore
./scripts/custom_restore.sh      # Custom restore
./scripts/manage_restore_points.sh  # Manage backups
```

### Manual Setup (Alternative)
```bash
# Create credentials file manually
cat > .nutanix_creds << 'EOF'
export PRISM="your-prism-central-ip"
export USER="your-username"
export PASS="your-password"
EOF
chmod 600 .nutanix_creds
```

## Usage Examples

### Setup Wizard
```
./scripts/setup_wizard.sh
1. Check prerequisites and dependencies
2. Configure Nutanix credentials with validation
3. Test API connectivity
4. View setup summary and next steps
```

### Export VMs
```
./scripts/export_menu.sh
1. Browse VMs by project (🟢 ON, 🔴 OFF indicators)
2. Select VMs: [number], 'a' (all), 'proj' (by project)
3. Export: 'e' → Monitor progress → Download → Optional cleanup
```

### Bulk Restore
```
./scripts/restore_menu.sh  
1. Select backup point (vm-export-YYYY-MM-DD_HH-MM-SS/)
2. Select VMs to restore
3. Restore: 'r' → Upload → Restore with original settings
```

### Custom Restore
```
./scripts/custom_restore.sh
1. Select VM → Choose restore point
2. Configure: VM name, subnets, project
3. Upload → Restore with custom settings
```

### Manage Restore Points
```
./scripts/manage_restore_points.sh
1. View all restore points with details
2. Delete individual or multiple restore points
3. View storage statistics by project
```

## Output Structure

```
scripts/
├── setup_wizard.sh                      # Interactive setup and configuration
├── export_menu.sh                       # VM export functionality
├── restore_menu.sh                      # Bulk VM restoration
├── custom_restore.sh                    # Single VM restore with customization
├── manage_restore_points.sh             # Backup management
└── ui_lib.sh                           # Shared UI library and functions

restore-points/
└── vm-export-YYYY-MM-DD_HH-MM-SS/
    ├── vm_export_tasks.csv              # Export metadata  
    ├── {vm_uuid}.ova                    # VM backup files
    └── restore_tasks_*.csv              # Restore logs

.nutanix_creds                           # Credentials file (auto-generated)
```

## Navigation Commands

| Command | Action |
|---------|--------|
| `[number]` | Select/toggle VM |
| `n/p` | Next/previous page |
| `a/c` | Select all/clear |
| `proj` | Select by project |
| `s` | Show selections |
| `e/r` | Export/restore |
| `d` | Delete (in management) |
| `q` | Quit |

### Setup Wizard Navigation
| Command | Action |
|---------|--------|
| `1` | Check prerequisites |
| `2` | Configure credentials |
| `3` | Test API connection |
| `4` | View current configuration |
| `5` | Reset configuration |
| `6` | Exit wizard |

## Configuration

Environment variables in `.nutanix_creds`:
- `PRISM` - Prism Central IP
- `USER` - Username  
- `PASS` - Password

Script configuration:
- `items_per_page=15` - VMs per page
- `POLL_INTERVAL=3` - Status check frequency  
- `CHUNK_SIZE=100MB` - Upload chunk size

Setup wizard configuration:
- Validates IP addresses and hostnames
- Tests API connectivity before saving
- Sets secure file permissions (600) on credentials
- Provides guided troubleshooting for common issues

## API Integration

Uses Nutanix Prism Central v3 REST API:
- **VM Operations**: List, export, create
- **OVA Management**: Upload, download, delete  
- **Resource Discovery**: Subnets, projects, clusters
- **Progress Tracking**: Task status monitoring

## Security Notes

- Never commit `.nutanix_creds` to version control
- Use HTTPS for all API calls
- Validate all user inputs
- Use dedicated service account for API access

## Troubleshooting

**Common Issues:**
- Check file permissions on scripts and credentials
- Verify network connectivity to Prism Central  
- Ensure all prerequisites are installed: `jq`, `curl`, `openssl`, `base64`
- Monitor disk space in target directories
- Run setup wizard to verify configuration: `./scripts/setup_wizard.sh`

**Setup Wizard Issues:**
- Run with `--quick` flag for non-interactive setup
- Check bash version (requires 4.0+): `echo $BASH_VERSION`
- Verify credentials file permissions: `ls -la .nutanix_creds`
- Test network connectivity: `ping your-prism-central-ip`

**Debug Mode:**
```bash
# Add to script for detailed logging
set -x  # Enable bash debug mode
curl -v ...  # Verbose curl output
```

---

**Version**: 2.4 | **Compatibility**: Nutanix Prism Central v3 API | **Requirements**: Bash 4.0+, jq, curl, openssl, base64

## Recent Updates

### ✨ **Version 2.4 Features**
- 🛠️ **Setup Wizard**: Interactive configuration with credential validation and API testing
- 📁 **Organized Structure**: All scripts moved to `scripts/` directory for better organization
- 📚 **Shared UI Library**: Standardized functions in `ui_lib.sh` for consistent user experience
- 🔒 **Enhanced Security**: Automatic credential file permissions and validation
- 🎯 **Better Prerequisites**: Comprehensive dependency checking with installation guidance
- 📋 **Improved Documentation**: Updated README and new CLAUDE.md for development guidance