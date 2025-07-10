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
| **`manage_restore_points.sh`** | Manage backup restore points | Cleanup, storage management, audit |
| **`web-interface/`** | Web-based dashboard and management | Remote access, non-technical users |

## Workflow

```
Export: VM Selection → Export → Download → Cleanup
Bulk Restore: Backup Selection → VM Selection → Upload → Restore  
Custom Restore: VM Selection → Restore Point → Configure → Upload → Restore
Management: View Restore Points → Delete/Statistics → Cleanup
Web Interface: Browser Dashboard → VM Management → Remote Operations
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
./vm_export_menu.sh         # Export VMs
./vm_restore_menu.sh        # Bulk restore
./vm_custom_restore.sh      # Custom restore
./manage_restore_points.sh  # Manage backups

# 4. Optional: Start web interface
cd web-interface
./install.sh               # Install web dependencies
./start_web_interface.sh    # Start web server
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

### Manage Restore Points
```
./manage_restore_points.sh
1. View all restore points with details
2. Delete individual or multiple restore points
3. View storage statistics by project
```

### Web Interface
```
cd web-interface && ./start_web_interface.sh
1. Open browser to http://localhost:5000
2. Dashboard with VM counts and statistics
3. Browse VMs with search/filter capabilities
4. View and manage restore points with deletion
5. Detailed VM contents view for each restore point
6. Professional formatted VM details dialog
```

## Output Structure

```
restore-points/
└── vm-export-YYYY-MM-DD_HH-MM-SS/
    ├── vm_export_tasks.csv              # Export metadata  
    ├── {vm_uuid}.ova                    # VM backup files
    └── restore_tasks_*.csv              # Restore logs

web-interface/
├── app.py                               # Flask web application
├── install.sh                           # Web interface installer
├── start_web_interface.sh               # Startup script
├── static/                              # CSS, JavaScript assets
└── templates/                           # HTML templates
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

### Web Interface Navigation
| Action | Method |
|---------|--------|
| Switch tabs | Click Dashboard/VMs/Restore Points |
| Search VMs | Type in search box |
| Filter by project/state | Use dropdown filters |
| View VM details | Click "👁️ Details" button |
| Select VMs | Use checkboxes |
| Export VMs | Click "📤 Export Selected VMs" |
| View restore point contents | Click "👁️ View VMs" button |
| Delete restore points | Select checkboxes → "🗑️ Delete Selected" |
| Copy VM UUIDs | Click UUID in restore point contents |

## Configuration

Environment variables in `.nutanix_creds`:
- `PRISM` - Prism Central IP
- `USER` - Username  
- `PASS` - Password

Script configuration:
- `items_per_page=15` - VMs per page
- `POLL_INTERVAL=3` - Status check frequency  
- `CHUNK_SIZE=100MB` - Upload chunk size

Web interface configuration:
- Default port: `5000` (change in `app.py`)
- Auto-refresh: Real-time data loading
- Mobile responsive: Works on phones/tablets

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

**Web Interface Issues:**
- Install Python 3 and Flask: `pip3 install flask`
- Check firewall: `sudo ufw allow 5000/tcp`
- Access remotely: `http://[server-ip]:5000`
- View logs in terminal where web server is running

**Debug Mode:**
```bash
# Add to script for detailed logging
set -x  # Enable bash debug mode
curl -v ...  # Verbose curl output
```

---

**Version**: 2.3 | **Compatibility**: Nutanix Prism Central v3 API | **Web Interface**: Flask 2.3.3

## Web Interface Features

### 🎯 **Current Features (Phase 1 - Complete)**
- ✅ **Dashboard**: VM counts, restore points, storage statistics
- ✅ **VM Browser**: Search, filter by project/power state
- ✅ **VM Details**: Professional formatted dialog with virtual machine specs
- ✅ **Restore Points Management**: Table view with comprehensive operations
- ✅ **Restore Point Contents**: Detailed VM list with file status verification
- ✅ **Delete Functionality**: Safe deletion of individual/multiple restore points
- ✅ **Interactive Features**: Click-to-copy UUIDs, bulk selection, confirmation dialogs
- ✅ **Mobile Responsive**: Optimized for phones, tablets, and desktop
- ✅ **Real-time Data**: Auto-loading from Nutanix API with error handling

### 🔧 **Phase 1 Enhancements Completed**
- **Professional Table Layout**: Consistent design across VM and restore point views
- **Advanced Delete Operations**: Type "DELETE" confirmation with detailed previews
- **Optimized Modal Design**: Appropriate sizing with single-scrollbar UX
- **Enhanced Data Display**: Proper CSV parsing with file existence validation
- **Safety Features**: Cannot close modals accidentally, explicit confirmation required

### 🚀 **Coming Soon (Phase 2)**
- 📤 **VM Export**: Web-based export with progress tracking
- 📥 **VM Restore**: Web-based restore functionality  
- 🔔 **Notifications**: Real-time operation status updates
- 📊 **Advanced Analytics**: Storage trends and usage patterns
- 🔄 **Background Operations**: Async export/restore with progress bars