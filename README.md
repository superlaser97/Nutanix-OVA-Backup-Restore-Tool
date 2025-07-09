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
| **`vm_export_menu.sh`** | Export VMs to OVA backups | Regular backups, migration prep |
| **`vm_restore_menu.sh`** | Bulk restore multiple VMs | Disaster recovery, environment restore |
| **`vm_custom_restore.sh`** | Single VM restore with custom settings | Selective recovery, cross-project moves |

## Workflow

```
Export: VM Selection → Export → Download → Cleanup
Bulk Restore: Backup Selection → VM Selection → Upload → Restore  
Custom Restore: VM Selection → Restore Point → Configure → Upload → Restore
```

## Quick Start

### Prerequisites
- `jq` and `curl` installed
- Network access to Nutanix Prism Central
- Valid Nutanix credentials

### Setup
```bash
# 1. Create credentials file
cat > .nutanix_creds << 'EOF'
export PRISM="your-prism-central-ip"
export USER="your-username"
export PASS="your-password"
EOF

# 2. Make scripts executable
chmod +x *.sh

# 3. Run desired script
./vm_export_menu.sh      # Export VMs
./vm_restore_menu.sh     # Bulk restore
./vm_custom_restore.sh   # Custom restore
```

## Usage Examples

### Export VMs
```
./vm_export_menu.sh
1. Browse VMs by project (🟢 ON, 🔴 OFF indicators)
2. Select VMs: [number], 'a' (all), 'proj' (by project)
3. Export: 'e' → Monitor progress → Download → Optional cleanup
```

### Bulk Restore
```
./vm_restore_menu.sh  
1. Select backup point (vm-export-YYYY-MM-DD_HH-MM-SS/)
2. Select VMs to restore
3. Restore: 'r' → Upload → Restore with original settings
```

### Custom Restore
```
./vm_custom_restore.sh
1. Select VM → Choose restore point
2. Configure: VM name, subnets, project
3. Upload → Restore with custom settings
```

## Output Structure

```
vm-export-YYYY-MM-DD_HH-MM-SS/
├── vm_export_tasks.csv              # Export metadata  
├── {vm_uuid}.ova                    # VM backup files
└── restore_tasks_*.csv              # Restore logs
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
| `q` | Quit |

## Configuration

Environment variables in `.nutanix_creds`:
- `PRISM` - Prism Central IP
- `USER` - Username  
- `PASS` - Password

Script configuration:
- `items_per_page=15` - VMs per page
- `POLL_INTERVAL=3` - Status check frequency
- `CHUNK_SIZE=100MB` - Upload chunk size

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
- Ensure `jq` and `curl` are installed
- Monitor disk space in target directories

**Debug Mode:**
```bash
# Add to script for detailed logging
set -x  # Enable bash debug mode
curl -v ...  # Verbose curl output
```

---

**Version**: 2.1 | **Compatibility**: Nutanix Prism Central v3 API