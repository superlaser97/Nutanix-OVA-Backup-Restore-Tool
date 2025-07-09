# VM Export Menu Script

A comprehensive interactive script for exporting and downloading VMs from Nutanix Prism Central with an intuitive menu-driven interface.

## 📋 Overview

This script provides a user-friendly way to:
- Browse and select VMs from Nutanix Prism Central
- Export selected VMs to OVA format
- Download the exported OVA files
- Clean up OVA files from Prism Central after download

## 🚀 Quick Start

### Prerequisites
- Linux environment with bash shell
- `jq` - JSON processor (`apt install jq` or `yum install jq`)
- `curl` - HTTP client (`apt install curl` or `yum install curl`)
- Network access to Nutanix Prism Central
- Valid Nutanix credentials

### Setup
1. **Create credentials file**:
   ```bash
   # Create .nutanix_creds file in the same directory as the script
   cat > .nutanix_creds << 'EOF'
   export PRISM="your-prism-central-ip"
   export USER="your-username"
   export PASS="your-password"
   EOF
   ```

2. **Make script executable**:
   ```bash
   chmod +x vm_export_menu.sh
   ```

3. **Run the script**:
   ```bash
   ./vm_export_menu.sh
   ```

## 🎯 For Non-Technical Users

### What This Script Does
Think of this script as a **digital assistant** that helps you:
1. **Browse** all your virtual machines (VMs) like browsing files in a folder
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
  1) Blank VM                    
  4) Common Services VM          
  7) Management Services VM      

Project: Tenant 1
----------------------------------------
  12) display-app               [SELECTED]
  13) display-db                
  15) display-worker            
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
- **Weekly backups**: Select and export critical VMs regularly
- **Migration preparation**: Export VMs before moving to new infrastructure
- **Disaster recovery**: Create offline backups of important systems
- **Development**: Export test VMs for deployment elsewhere

## 🔧 For Technical Users

### Architecture
The script follows a three-phase workflow:
1. **Selection Phase**: Interactive menu with pagination and filtering
2. **Export Phase**: Parallel API calls with progress monitoring
3. **Download Phase**: Sequential OVA file retrieval with optional cleanup

### Technical Features

#### API Integration
- **Nutanix v3 REST API** for VM listing, export, and OVA management
- **Authenticated requests** using basic auth over HTTPS
- **Error handling** with proper HTTP status code checking
- **JSON parsing** with `jq` for robust data extraction

#### Data Structures
```bash
# VM data format: "project|vm_name|vm_uuid"
vm_data=("DICE Internal|Blank VM|d155d064-96b8-4033-8381-d3907da0cf81")

# Selection tracking
selected=([1]=1 [5]=1 [12]=1)  # Associative array of selected indices

# Task tracking
task_map=([vm_uuid]="task_uuid")  # Maps VM UUIDs to export task UUIDs
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

```
vm-export-2025-01-09_14-30-22/
├── vm_export_tasks.csv          # Export metadata and task tracking
├── d155d064-96b8-4033-8381-d3907da0cf81.ova  # VM export files
├── ca6d4168-3e21-4e8a-91d9-5544849be394.ova
└── e15b74f4-da5b-48b1-9559-215e576ebfd9.ova
```

### CSV Format
```csv
VM_NAME,VM_UUID,PROJECT_NAME,TASK_UUID,OVA_NAME
Blank VM,d155d064-96b8-4033-8381-d3907da0cf81,DICE Internal,task-123,d155d064-96b8-4033-8381-d3907da0cf81
```

## 🛠️ Command Reference

### Navigation Commands
- `n` / `N` - Next page
- `p` / `P` - Previous page
- `f` / `F` - First page
- `l` / `L` - Last page

### Selection Commands
- `[number]` - Toggle VM selection (e.g., `12`)
- `a` - Select all VMs
- `c` - Clear all selections
- `proj` - Select VMs by project
- `s` - Show selection summary

### Action Commands
- `e` - Export selected VMs
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

**Last Updated**: January 2025  
**Version**: 1.0  
**Compatibility**: Nutanix Prism Central v3 API