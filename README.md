# Nutanix OVA Backup & Restore Tool

A comprehensive suite of interactive scripts for backing up and restoring VMs from Nutanix Prism Central with intuitive menu-driven interfaces.

## 📖 Table of Contents

- [📋 Overview](#-overview)
- [🚀 Quick Start](#-quick-start)
  - [Prerequisites](#prerequisites)
  - [Setup](#setup)
- [🎯 For Non-Technical Users](#-for-non-technical-users)
  - [What This Script Does](#what-this-script-does)
  - [How to Use It](#how-to-use-it)
  - [Common Use Cases](#common-use-cases)
- [🔧 For Technical Users](#-for-technical-users)
  - [Architecture](#architecture)
  - [Technical Features](#technical-features)
  - [Data Structures](#data-structures)
  - [File Management](#file-management)
  - [Advanced Configuration](#advanced-configuration)
  - [Integration Examples](#integration-examples)
  - [Troubleshooting](#troubleshooting)
- [📁 Output Structure](#-output-structure)
- [🛠️ Command Reference](#️-command-reference)
- [🔒 Security Notes](#-security-notes)
- [📊 Monitoring and Logging](#-monitoring-and-logging)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

## 📋 Overview

This toolkit provides three main scripts:

### 🔄 **vm_export_menu.sh** - VM Export & Backup
- Browse and select VMs from Nutanix Prism Central with power state indicators
- Export selected VMs to OVA format
- Download the exported OVA files
- Clean up OVA files from Prism Central after download

### 🔄 **vm_restore_menu.sh** - VM Restore & Recovery (Bulk)
- Browse available backup restore points with size information
- Select multiple VMs to restore from backup
- Upload OVA files back to Prism Central in parallel
- Restore VMs with original names and configurations
- Clean up uploaded OVA files after restoration

### 🎯 **vm_custom_restore.sh** - Custom VM Restoration (Individual)
- **Two-stage selection**: First select VM, then choose restore point
- **Multi-subnet support**: Select multiple subnets for VM network interfaces
- **Custom VM naming**: Override original VM name with custom name
- **Cross-project restoration**: Move VMs between projects during restore
- **Real-time progress monitoring**: Visual progress table with status updates
- **Intelligent defaults**: Uses original VM name from backup metadata as default
- **Resource discovery**: Automatically detects available subnets and projects
- **Error handling**: Debug mode with detailed error reporting
- **Clean OVA naming**: Uploads OVAs with UUID naming (no .ova extension)

## 🚀 Quick Start

### Prerequisites
- Linux environment with bash shell
- `jq` - JSON processor (`apt install jq` or `yum install jq`)
- `curl` - HTTP client (`apt install curl` or `yum install curl`)
- `sha1sum` - Checksum utility (for restore operations)
- Network access to Nutanix Prism Central
- Valid Nutanix credentials

### Setup
1. **Create credentials file**:
   ```bash
   # Create .nutanix_creds file in the same directory as the scripts
   cat > .nutanix_creds << 'EOF'
   export PRISM="your-prism-central-ip"
   export USER="your-username"
   export PASS="your-password"
   EOF
   ```

2. **Make scripts executable**:
   ```bash
   chmod +x vm_export_menu.sh
   chmod +x vm_restore_menu.sh
   chmod +x vm_custom_restore.sh
   ```

3. **Run the scripts**:
   ```bash
   # For VM export/backup
   ./vm_export_menu.sh
   
   # For bulk VM restore/recovery
   ./vm_restore_menu.sh
   
   # For custom single VM restoration
   ./vm_custom_restore.sh
   ```

## 🎯 For Non-Technical Users

### What This Script Does
Think of this script as a **digital assistant** that helps you:
1. **Browse** all your virtual machines (VMs) like browsing files in a folder, with power state indicators (🟢 ON, 🔴 OFF)
2. **Select** which VMs you want to backup
3. **Export** them to a standard backup format (OVA files)
4. **Download** the backup files to your local storage
5. **Clean up** temporary files from the server

### How to Use It

#### Step 1: Starting the Script
When you run the script, you'll see a menu showing all your VMs organized by project:

```
=========================================
         VM Export Selection Menu
=========================================

Available VMs (sorted by project, then name):
Page 1 of 3 | Showing 1-15 of 42 VMs

Project: DICE Internal
----------------------------------------
  1) Blank VM                    🔴 OFF     
  4) Common Services VM          🟢 ON      
  7) Management Services VM      🟢 ON      

Project: Tenant 1
----------------------------------------
  12) display-app               🟢 ON      [SELECTED]
  13) display-db                🔴 OFF     
  15) display-worker            🟢 ON      
```

#### Step 2: Navigating and Selecting
- **Browse pages**: Use `n` (next) and `p` (previous) to navigate through VMs
- **Select individual VMs**: Type the number (e.g., `12`) to toggle selection
- **Select all VMs in a project**: Type `proj` to choose an entire project
- **View your selections**: Type `s` to see what you've selected
- **Clear selections**: Type `c` to start over

#### Step 3: Export Process
- Type `e` to start exporting your selected VMs
- The script will show a progress table:
  ```
  Export Progress:
  
  VM_NAME                PROJECT         PROGRESS   STATUS
  ----------------------------------------------------------------
  display-app            Tenant 1        100%       SUCCEEDED
  display-db             Tenant 1        75%        RUNNING
  ```

#### Step 4: Download (Optional)
- After export completes, you can download the files to your computer
- Files are saved in a timestamped folder (e.g., `vm-export-2025-01-09_14-30-22/`)

#### Step 5: Cleanup (Optional)
- The script offers to delete temporary files from the server
- This frees up storage space and keeps things tidy

### Common Use Cases

#### Export & Backup (vm_export_menu.sh)
- **Weekly backups**: Select and export critical VMs regularly
- **Migration preparation**: Export VMs before moving to new infrastructure
- **Disaster recovery**: Create offline backups of important systems
- **Development**: Export test VMs for deployment elsewhere

#### Bulk Restoration (vm_restore_menu.sh)
- **Disaster recovery**: Quickly restore multiple VMs from a backup point
- **Environment recreation**: Restore entire project environments
- **Migration completion**: Restore VMs to new infrastructure

#### Custom Restoration (vm_custom_restore.sh)
- **Selective recovery**: Restore specific VM versions from any backup point
- **Cross-project migration**: Move VMs between projects during restoration
- **Multi-network configuration**: Attach VMs to multiple subnets simultaneously
- **Development testing**: Restore VMs with different names for testing
- **Version comparison**: Compare multiple backup versions of the same VM
- **Flexible naming**: Override VM names while preserving original metadata
- **Network isolation**: Create VMs with custom network configurations
- **Staged deployment**: Restore VMs incrementally with custom settings

## 🎯 Custom Restoration Workflow (vm_custom_restore.sh)

### Step-by-Step Process

#### 1. VM Discovery & Selection
```
=========================================
     Custom VM Restore - Select VM
=========================================

Available VMs (sorted by project, then name):
Page 1 of 2 | Showing 1-15 of 25 VMs

Project: DICE Internal
----------------------------------------
  1) Blank VM                    (3 restore points)
  2) Common Services VM          (1 restore points)

Project: Tenant 1
----------------------------------------
  3) display-app                 (5 restore points)
  4) display-db                  (2 restore points)
```

#### 2. Restore Point Selection
```
=========================================
   Restore Points for: display-app
=========================================

Project: Tenant 1

Available restore points (latest first):

 1) 9 Jul 2025, 3:11:33 AM (1024MB)
 2) 8 Jul 2025, 2:45:22 PM (1024MB) 
 3) 7 Jul 2025, 1:30:15 PM (1024MB)
 4) 6 Jul 2025, 4:20:10 PM (1024MB)
 5) 5 Jul 2025, 11:15:45 AM (1024MB)
```

#### 3. VM Name Configuration
```
=========================================
      Configure VM Restoration
=========================================

Original VM: display-app (Project: Tenant 1)

VM Name Configuration:
Default: display-app

Enter new VM name (or press Enter for default): display-app-test

Selected VM name: display-app-test
```

#### 4. Multi-Subnet Selection
```
=========================================
        Select Subnets for VM
=========================================

Available subnets:

 1) Nutanix Services Subnet          [SELECTED]
 2) Tenant 1 Subnet                  
 3) Tenant 2 Subnet                  [SELECTED]
 4) Tenant 3 Subnet                  
 5) Tenant Upstream Subnet           

Actions:
  [number] - Toggle subnet selection
  a        - Select all subnets
  c        - Clear all selections
  o        - Use original subnets from OVA
  done     - Finish subnet selection
  b        - Back

Selected: 2 subnets
```

#### 5. Project Selection
```
=========================================
        Select Project for VM
=========================================

Available projects:

 1) DICE Internal
 2) Tenant 1
 3) Tenant 2
 4) Development

Actions:
  [number] - Select project
  o        - Use original project from backup
  b        - Back
```

#### 6. Configuration Summary
```
=========================================
      Restoration Configuration Summary
=========================================

VM Name:     display-app-test
Subnets:     Nutanix Services Subnet
             Tenant 2 Subnet
Project:     Development

Proceed with restoration? (y/N):
```

#### 7. Real-Time Progress Monitoring
```
Restore Progress:

VM_NAME           PROJECT     OVA_FILE                              STATUS            PROGRESS
-------------------------------------------------------------------------------------------
display-app-test  Development d155d064-96b8-4033-8381-d3907da0cf81  UPLOADING         67%
```

#### 8. Successful Completion
```
🎉 Custom restoration completed successfully!

Restored VM Details:
  Name:     display-app-test
  UUID:     cadcceed-f62c-4c2c-8b28-261f91f5cf97
  Project:  Development
  Subnets:  Nutanix Services Subnet
            Tenant 2 Subnet

Delete uploaded OVA from Prism Central? (y/N):
```

### Key Features

- **Intelligent Defaults**: VM name defaults to original from backup metadata
- **Multi-NIC Support**: Each selected subnet creates a separate network interface
- **Resource Discovery**: Automatically fetches available subnets and projects
- **Progress Monitoring**: Real-time status updates during upload and restoration
- **Error Handling**: Debug mode provides detailed error information
- **Clean Naming**: OVAs uploaded with UUID naming (no .ova extension)
- **Flexible Configuration**: All settings can be customized or kept as original

## 🔧 For Technical Users

### Architecture

#### Export Script (vm_export_menu.sh)
Follows a three-phase workflow:
1. **Selection Phase**: Interactive menu with pagination and filtering
2. **Export Phase**: Parallel API calls with progress monitoring
3. **Download Phase**: Sequential OVA file retrieval with optional cleanup

#### Bulk Restore Script (vm_restore_menu.sh)
Follows a restore workflow:
1. **Backup Selection**: Choose from available vm-export-* restore points
2. **VM Selection**: Select VMs from the chosen backup point
3. **Upload & Restore**: Parallel upload with sequential VM restoration

#### Custom Restore Script (vm_custom_restore.sh)
Follows a comprehensive customization workflow:
1. **VM Discovery**: List unique VMs across all backup points with restore count
2. **Restore Point Selection**: Choose specific backup version with timestamp details
3. **VM Name Configuration**: Set custom VM name (defaults to original from CSV)
4. **Multi-Subnet Selection**: Choose multiple subnets with toggle interface
5. **Project Selection**: Select target project or use original
6. **Configuration Review**: Summary of all customizations before proceeding
7. **Upload & Restore**: Individual file upload with real-time progress monitoring
8. **Validation**: Automatic cleanup with optional OVA deletion from Prism Central

### Technical Features

#### API Integration
- **Nutanix v3 REST API** for VM listing, export, upload, and OVA management
- **Authenticated requests** using basic auth over HTTPS
- **Error handling** with proper HTTP status code checking
- **JSON parsing** with `jq` for robust data extraction
- **Resource discovery** for subnets, projects, and clusters
- **Chunked uploads** for large OVA files with progress tracking
- **VM specification extraction** from OVA files for restoration

#### Data Structures

**Export Script:**
```bash
# VM data format: "project|vm_name|vm_uuid|power_state"
vm_data=("DICE Internal|Blank VM|d155d064-96b8-4033-8381-d3907da0cf81|OFF")

# Selection tracking
selected=([1]=1 [5]=1 [12]=1)  # Associative array of selected indices

# Task tracking
task_map=([vm_uuid]="task_uuid")  # Maps VM UUIDs to export task UUIDs
```

**Restore Scripts:**
```bash
# VM data format with restore info: "project|vm_name|vm_uuid|ova_name|ova_file"
vm_data=("Project|VM-Name|uuid|ova_name|/path/to/file.ova")

# Resource mapping for restoration
SUBNET_MAP=(["subnet-name"]="subnet-uuid")
PROJECT_MAP=(["project-name"]="project-uuid")

# Custom restore: VM to restore points mapping
vm_restore_points=(["project|vm_name"]="date1:path1;date2:path2")

# Multi-subnet selection arrays
SELECTED_SUBNETS=("subnet1" "subnet2" "subnet3")
SELECTED_SUBNET_UUIDS=("uuid1" "uuid2" "uuid3")
```

#### File Management
- **CSV task log**: `vm_export_tasks.csv` with complete export metadata
- **Timestamped directories**: `vm-export-YYYY-MM-DD_HH-MM-SS/`
- **OVA naming**: Files saved as `{vm_uuid}.ova` for uniqueness
- **Atomic operations**: All files created in single target directory

### Advanced Configuration

#### Pagination Settings
```bash
items_per_page=15  # VMs per page (configurable)
```

#### Upload Settings (Restore Scripts)
```bash
CHUNK_SIZE=$((100 * 1024 * 1024))  # 100MB chunks for upload
MAX_UPLOAD_JOBS=4                  # Parallel upload limit
POLL_INTERVAL=5                    # Seconds between status checks
```

#### API Parameters
```bash
# VM listing
curl -X POST "https://$PRISM/api/nutanix/v3/vms/list" \
  -H 'Content-Type: application/json' \
  -d '{"length":1000}'

# VM export
curl -X POST "https://$PRISM/api/nutanix/v3/vms/$uuid/export" \
  -H 'Content-Type: application/json' \
  -d '{"disk_file_format":"QCOW2","name":"'$uuid'"}'

# OVA upload (chunked)
curl -X PUT "https://$PRISM/api/nutanix/v3/ovas/$uuid/chunks" \
  -H 'Content-Type: application/octet-stream' \
  -H "X-Nutanix-Upload-Offset:$offset" \
  --data-binary @chunk_file

# VM creation from OVA
curl -X POST "https://$PRISM/api/nutanix/v3/vms" \
  -H 'Content-Type: application/json' \
  -d "$vm_specification_payload"
```

#### Error Handling
- **Set strict mode**: `set -eu` for immediate error detection
- **Credential validation**: Automatic failure if `.nutanix_creds` missing
- **API response validation**: JSON parsing with fallback for missing fields
- **Graceful degradation**: Continues processing other VMs if one fails

### Security Considerations
- **Credential isolation**: Separate `.nutanix_creds` file (add to `.gitignore`)
- **HTTPS enforcement**: All API calls use SSL/TLS
- **Input validation**: Numeric input validation for menu choices
- **Session management**: No persistent credential storage

### Performance Features
- **Parallel exports**: Multiple VM exports submitted simultaneously
- **Progress monitoring**: Real-time status updates with configurable polling
- **Bandwidth optimization**: Sequential downloads to avoid overwhelming network
- **Memory efficiency**: Streaming downloads without loading entire files

### Customization Options

#### Modify column widths:
```bash
DEFAULT_NAME_WIDTH=7
UUID_DISPLAY_LENGTH=10
PROJECT_COL_WIDTH=15
```

#### Adjust polling frequency:
```bash
POLL_INTERVAL=3  # seconds between status checks
```

#### Change export format:
```bash
# In export API call, modify disk_file_format
-d '{"disk_file_format":"VMDK","name":"'$uuid'"}'  # For VMware
```

#### Customize restore behavior:
```bash
# Skip subnet modification in custom restore
SELECTED_SUBNET_UUID=""  # Use original subnet

# Skip project modification in custom restore  
SELECTED_PROJECT_UUID=""  # Use original project
```

### Integration Examples

#### Automated Workflow
```bash
# Pre-select VMs programmatically
echo "12,15,18" | ./vm_export_menu.sh  # Not implemented but shows concept
```

#### Monitoring Integration
```bash
# Parse CSV output for monitoring systems
tail -f vm_export_tasks.csv | while IFS=, read name uuid project task ova; do
  echo "METRIC vm_export_started{name=\"$name\",project=\"$project\"} 1"
done
```

### Troubleshooting

#### Common Issues
1. **Permission denied**: Check file permissions on script and credentials
2. **API authentication**: Verify credentials and network connectivity
3. **JSON parsing errors**: Ensure `jq` is installed and API responses are valid
4. **Disk space**: Monitor available space in target directory

#### Debug Mode
Add debug output by modifying the script:
```bash
# Enable debug mode
set -x  # Add after set -eu

# Verbose curl output
curl -v -k -u "$USER:$PASS" ...
```

#### Log Analysis
```bash
# Monitor API calls
grep "curl" vm_export_menu.sh  # Find all API endpoints

# Check task completion
grep "SUCCEEDED" vm_export_tasks.csv
```

## 📁 Output Structure

### Export Output
```
vm-export-2025-01-09_14-30-22/
├── vm_export_tasks.csv          # Export metadata and task tracking
├── d155d064-96b8-4033-8381-d3907da0cf81.ova  # VM export files
├── ca6d4168-3e21-4e8a-91d9-5544849be394.ova
└── e15b74f4-da5b-48b1-9559-215e576ebfd9.ova
```

### Restore Logs
```
restore_tasks_2025-01-09_15-45-33.csv  # Individual restore logs
```

### CSV Formats

**Export Tasks (vm_export_tasks.csv):**
```csv
VM_NAME,VM_UUID,PROJECT_NAME,TASK_UUID,OVA_NAME
Blank VM,d155d064-96b8-4033-8381-d3907da0cf81,DICE Internal,task-123,d155d064-96b8-4033-8381-d3907da0cf81
```

**Restore Tasks (restore_tasks_*.csv):**
```csv
VM_NAME,PROJECT_NAME,OVA_UUID,NEW_VM_UUID,TASK_UUID
VM-Web-01,ProjectA,ova-uuid-123,new-vm-uuid-456,restore-task-789
```

## 🛠️ Command Reference

### Navigation Commands
- `n` / `N` - Next page
- `p` / `P` - Previous page
- `f` / `F` - First page
- `l` / `L` - Last page

### Selection Commands (Export & Bulk Restore)
- `[number]` - Toggle VM selection (e.g., `12`)
- `a` - Select all VMs
- `c` - Clear all selections
- `proj` - Select VMs by project
- `s` - Show selection summary

### Action Commands
- `e` - Export selected VMs (export script)
- `r` - Restore selected VMs (restore script)
- `q` - Quit script
- `b` - Back to previous menu (custom restore)

### Custom Restore Commands

#### VM & Restore Point Selection
- `[number]` - Select VM to see restore points
- `[number]` - Select restore point to restore
- Navigation: `n/p/f/l` for next/previous/first/last page

#### Multi-Subnet Selection
- `[number]` - Toggle subnet selection
- `a` - Select all subnets
- `c` - Clear all subnet selections
- `done` - Finish subnet selection
- `o` - Use original subnets from OVA

#### Project Selection
- `[number]` - Select target project
- `o` - Use original project from backup

#### General Commands
- `b` - Back to previous menu
- `q` - Quit script

## 🔒 Security Notes

- Never commit `.nutanix_creds` to version control
- Use dedicated service account for API access
- Regularly rotate API credentials
- Monitor export/download activities
- Ensure proper network security (VPN, firewall rules)

## 📊 Monitoring and Logging

The script provides comprehensive logging:
- **Export tasks**: Detailed CSV with timestamps and status
- **Progress tracking**: Real-time status updates
- **Summary reports**: Success/failure statistics
- **Error reporting**: Clear error messages with context

## 🤝 Contributing

To extend or modify the script:
1. Follow existing code patterns and naming conventions
2. Test thoroughly with different VM configurations
3. Update documentation for any new features
4. Consider backward compatibility for existing workflows

## 📄 License

This script is provided as-is for educational and operational use. Please ensure compliance with your organization's policies regarding VM exports and data handling.

---

**Last Updated**: July 2025  
**Version**: 2.1  
**Compatibility**: Nutanix Prism Central v3 API

### Version History
- **v2.1 (July 2025)**: Enhanced vm_custom_restore.sh with multi-subnet support, improved VM naming, and debug mode
- **v2.0 (July 2025)**: Added vm_custom_restore.sh with individual VM restoration and configuration options
- **v1.5 (July 2025)**: Added vm_restore_menu.sh for bulk VM restoration
- **v1.0 (January 2025)**: Initial release with vm_export_menu.sh