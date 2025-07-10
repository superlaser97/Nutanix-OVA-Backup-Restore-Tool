# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Nutanix OVA (Open Virtual Appliance) backup and restore tool that provides an interactive menu system for managing VM exports from Nutanix Prism Central. The tool allows users to browse, select, export, and download VMs as OVA files, with optional cleanup of temporary files.

## Architecture

### Core Components

- **vm_export_menu.sh** - Main interactive script that handles the complete workflow
- **vm_restore_menu.sh** - Interactive script for bulk VM restoration from backup points
- **vm_custom_restore.sh** - Interactive script for custom VM restoration with advanced configuration options
- **manage_restore_points.sh** - Interactive script for managing backup restore points (view, delete, statistics)

### Main Script Structure (vm_export_menu.sh)

The script follows a three-phase workflow:

1. **VM Discovery & Selection Phase**
   - Fetches VM list from Nutanix Prism Central v3 API
   - Displays paginated menu organized by project
   - Handles user selections with multi-select capability

2. **Export Phase**
   - Submits export tasks to Nutanix API in parallel
   - Monitors export progress with real-time status updates
   - Tracks tasks in CSV format for audit trail

3. **Download & Cleanup Phase**
   - Downloads OVA files sequentially to avoid network overload
   - Optionally deletes temporary OVA files from Prism Central
   - Organizes output in timestamped directories within the `restore-points` folder

### Key Data Structures

- VM data format: `"project|vm_name|vm_uuid"` (pipe-delimited)
- Selection tracking: Associative array `selected=([index]=1)`
- Task mapping: `task_map=([vm_uuid]="task_uuid")`

## Prerequisites

- **jq** - JSON processor for API response parsing
- **curl** - HTTP client for API calls
- **bash** - Shell environment (script uses `#!/usr/bin/env bash`)
- Network access to Nutanix Prism Central
- Valid Nutanix credentials in `.nutanix_creds` file

## Configuration

### Credentials Setup
Create `.nutanix_creds` file in the same directory:
```bash
export PRISM="your-prism-central-ip"
export USER="your-username"
export PASS="your-password"
```

### Script Configuration Variables
- `POLL_INTERVAL=3` - Seconds between export status checks
- `items_per_page=15` - VMs displayed per page in menu

## Common Commands

### Running the Tools
```bash
# Export VMs to OVA backups
chmod +x vm_export_menu.sh
./vm_export_menu.sh

# Restore VMs from backup points (bulk restore)
chmod +x vm_restore_menu.sh
./vm_restore_menu.sh

# Custom VM restoration (individual restore with custom settings)
chmod +x vm_custom_restore.sh
./vm_custom_restore.sh

# Manage restore points (view, delete, statistics)
chmod +x manage_restore_points.sh
./manage_restore_points.sh
```

### Development/Testing
```bash
# Check prerequisites
command -v jq && command -v curl

# Validate credentials file
source .nutanix_creds && echo "PRISM: $PRISM, USER: $USER"

# Test API connectivity
curl -s -k -u "$USER:$PASS" -X POST "https://$PRISM/api/nutanix/v3/vms/list" -H 'Content-Type: application/json' -d '{"length":1}' | jq
```

## API Integration

The tool uses Nutanix Prism Central v3 REST API:

- **VM Listing**: `POST /api/nutanix/v3/vms/list`
- **VM Export**: `POST /api/nutanix/v3/vms/{uuid}/export`
- **Task Status**: `GET /api/nutanix/v3/tasks/{task_uuid}`
- **OVA Listing**: `POST /api/nutanix/v3/ovas/list`
- **OVA Download**: `GET /api/nutanix/v3/ovas/{uuid}/file`
- **OVA Upload**: `POST /api/nutanix/v3/ovas` + `PUT /api/nutanix/v3/ovas/{uuid}/chunks`
- **OVA Validation**: `POST /api/nutanix/v3/ovas/{uuid}/chunks/concatenate`
- **VM Creation**: `POST /api/nutanix/v3/vms`
- **VM Spec Extraction**: `GET /api/nutanix/v3/ovas/{uuid}/vm_spec`
- **OVA Deletion**: `DELETE /api/nutanix/v3/ovas/{uuid}`
- **Resource Listing**: `POST /api/nutanix/v3/{subnets|projects|clusters}/list`

## Output Structure

```
restore-points/
└── vm-export-YYYY-MM-DD_HH-MM-SS/
    ├── vm_export_tasks.csv          # Export metadata and task tracking
    ├── {vm_uuid}.ova               # Exported VM files
    └── {vm_uuid}.ova               # Additional exports...
```

## Security Notes

- Never commit `.nutanix_creds` to version control
- All API calls use HTTPS with basic authentication
- Script uses `set -eu` for strict error handling
- Input validation prevents injection attacks

## Backup Location

All backup files are stored in the `restore-points` folder within the project root directory. This includes:
- VM export backups (created by `vm_export_menu.sh`)
- All related CSV files and metadata
- OVA files downloaded from Nutanix Prism Central

The restore scripts (`vm_restore_menu.sh` and `vm_custom_restore.sh`) automatically search for backup folders in the `restore-points` directory.

## Restore Point Management

### manage_restore_points.sh

Interactive script for managing backup restore points with the following features:

**Key Features:**
- **View all restore points**: Lists all available backup restore points with timestamps, VM counts, and sizes
- **Individual restore point details**: Shows detailed information about each restore point including VM lists and file status
- **Delete restore points**: Safely delete individual restore points with confirmation prompts
- **Bulk deletion**: Select and delete multiple restore points at once
- **Storage statistics**: View storage usage by project and overall disk usage statistics
- **Color-coded output**: Enhanced visual interface with status indicators

**Menu Structure:**
1. **Main Menu**: Overview of all restore points with basic statistics
2. **Detail View**: Individual restore point information with VM breakdown
3. **Delete Operations**: Safe deletion with confirmation prompts
4. **Storage Statistics**: Comprehensive storage usage analysis

**Safety Features:**
- Requires typing "DELETE" to confirm destructive operations
- Shows detailed information before deletion
- Provides summary of successful/failed operations
- Cannot accidentally delete without explicit confirmation

## Custom Restore Script Features

### vm_custom_restore.sh

Advanced script for individual VM restoration with comprehensive customization:

**Key Features:**
- **Two-stage selection**: First select VM across all backups, then choose specific restore point
- **Multi-subnet support**: Select multiple subnets for VM network interfaces (creates multiple NICs)
- **Custom VM naming**: Override original VM name with custom name (defaults to original from CSV)
- **Cross-project restoration**: Move VMs between projects during restore
- **Real-time progress monitoring**: Visual progress table with status updates during upload/restore
- **Resource discovery**: Automatically detects and lists available subnets and projects
- **Intelligent defaults**: Uses original VM name from backup metadata as default
- **Clean OVA naming**: Uploads OVAs with UUID naming (no .ova extension)
- **Debug mode**: Detailed error reporting for troubleshooting

**Enhanced Workflow:**
1. **VM Discovery**: Browse unique VMs across all backup points with restore count indicators
2. **Restore Point Selection**: Choose specific backup version with timestamp and size details
3. **VM Name Configuration**: Set custom VM name (defaults to original from CSV)
4. **Multi-Subnet Selection**: Choose multiple subnets with toggle interface (creates separate NICs)
5. **Project Selection**: Select target project or use original from backup
6. **Configuration Review**: Summary of all customizations before proceeding
7. **Upload & Restore**: Individual file upload with real-time progress monitoring
8. **Cleanup**: Optional OVA deletion from Prism Central after successful restore

## Memories

### Project Updates
- There is no more legacy scripts, the "old" folder was removed