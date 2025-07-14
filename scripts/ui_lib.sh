#!/usr/bin/env bash

##############################################################
# ui_lib.sh
# ----------------------------------------------------------
# Common library for Nutanix OVA Backup/Restore Tool
# Provides standardized UI/UX, API functions, and utilities
# shared across all scripts in the toolset.
##############################################################

# Prevent multiple includes
if [[ -n "${UI_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly UI_LIB_LOADED=1

# Set strict error handling
set -euo pipefail

# ============================================================================
# CONSTANTS AND CONFIGURATION
# ============================================================================

# Version information
readonly UI_LIB_VERSION="1.0.0"

# Colors for output (standardized across all scripts)
readonly RED='\033[0;31m'        # Red for errors
readonly GREEN='\033[0;32m'      # Green for success
readonly YELLOW='\033[1;33m'     # Bright yellow for warnings
readonly CYAN='\033[0;36m'       # Cyan for info
readonly MAGENTA='\033[0;35m'    # Magenta for headers
readonly BOLD='\033[1m'          # Bold text
readonly DIM='\033[2m'           # Dim text
readonly UNDERLINE='\033[4m'     # Underline
readonly NC='\033[0m'            # No Color

# Status icons (standardized)
readonly SUCCESS="✅"
readonly ERROR="❌"
readonly WARNING="⚠️"
readonly INFO="ℹ️"
readonly LOADING="🔄"
readonly TRASH="🗑️"
readonly ROCKET="🚀"
readonly GEAR="⚙️"
readonly DISK="💾"
readonly CLOUD="☁️"
readonly ARROW="➤"

# Default configuration
readonly DEFAULT_POLL_INTERVAL=3
readonly DEFAULT_CHUNK_SIZE=$((100 * 1024 * 1024))  # 100MB chunks
readonly DEFAULT_ITEMS_PER_PAGE=15
readonly DEFAULT_TIMEOUT=120000  # 2 minutes in milliseconds

# File paths
readonly CREDS_FILE=".nutanix_creds"
readonly RESTORE_POINTS_DIR="restore-points"

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

# Script directory (auto-detected)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration variables (can be overridden)
POLL_INTERVAL=${POLL_INTERVAL:-$DEFAULT_POLL_INTERVAL}
CHUNK_SIZE=${CHUNK_SIZE:-$DEFAULT_CHUNK_SIZE}
ITEMS_PER_PAGE=${ITEMS_PER_PAGE:-$DEFAULT_ITEMS_PER_PAGE}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get current timestamp
get_timestamp() {
    date '+%Y-%m-%d_%H-%M-%S'
}

# Convert bytes to human readable format
human_readable_size() {
    local bytes=$1
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    
    if [[ $bytes -eq 0 ]]; then
        echo "0B"
        return
    fi
    
    while [[ $bytes -gt 1024 && $unit -lt 4 ]]; do
        bytes=$((bytes / 1024))
        ((unit++))
    done
    
    echo "${bytes}${units[$unit]}"
}

# Validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Validate hostname/FQDN
validate_hostname() {
    local hostname=$1
    if [[ $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    return 1
}

# ============================================================================
# UI/UX DISPLAY FUNCTIONS
# ============================================================================

# Print colored messages
print_success() {
    echo -e "${GREEN}${SUCCESS} $1${NC}"
}

print_error() {
    echo -e "${RED}${ERROR} $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}${WARNING} $1${NC}"
}

print_info() {
    echo -e "${CYAN}${INFO} $1${NC}"
}

print_loading() {
    echo -e "${CYAN}${LOADING} $1${NC}"
}

print_header() {
    local title="$1"
    local width=75
    local padding=$(( (width - ${#title} - 2) / 2 ))
    
    echo -e "\n${BOLD}${MAGENTA}$(printf '%*s' $width '' | tr ' ' '=')"
    printf "${BOLD}${MAGENTA}%*s %s %*s${NC}\n" $padding "" "$title" $padding ""
    echo -e "${BOLD}${MAGENTA}$(printf '%*s' $width '' | tr ' ' '=')"
    echo -e "${NC}"
}

print_section() {
    local title="$1"
    echo -e "\n${BOLD}${CYAN}${ARROW} $title${NC}"
    echo -e "${CYAN}$(printf '%*s' 65 '' | tr ' ' '─')${NC}"
}

print_menu_header() {
    local title="$1"
    print_header "$title"
}

print_menu_separator() {
    echo -e "${DIM}$(printf '%*s' 65 '' | tr ' ' '─')${NC}"
}

print_table_header() {
    local -a headers=("$@")
    local format=""
    local separator=""
    
    # Calculate format string and separator
    for header in "${headers[@]}"; do
        local width=${#header}
        if [[ $width -lt 10 ]]; then width=10; fi
        format+="%-${width}s  "
        separator+="$(printf '%*s' $((width + 2)) '' | tr ' ' '-')"
    done
    
    printf "${BOLD}${format}${NC}\n" "${headers[@]}"
    echo -e "${DIM}${separator}${NC}"
}

# ============================================================================
# TIMESTAMP CONVERSION FUNCTIONS
# ============================================================================

# Convert timestamp to readable format
timestamp_to_readable() {
    local timestamp="$1"
    
    if [[ $timestamp =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
        local year="${BASH_REMATCH[1]}"
        local month="${BASH_REMATCH[2]}"
        local day="${BASH_REMATCH[3]}"
        local hour="${BASH_REMATCH[4]}"
        local minute="${BASH_REMATCH[5]}"
        local second="${BASH_REMATCH[6]}"
        
        local month_names=("" "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
        local month_name="${month_names[$((10#$month))]}"
        
        local hour_12=$((10#$hour))
        local ampm="AM"
        if [[ $hour_12 -eq 0 ]]; then
            hour_12=12
        elif [[ $hour_12 -gt 12 ]]; then
            hour_12=$((hour_12 - 12))
            ampm="PM"
        elif [[ $hour_12 -eq 12 ]]; then
            ampm="PM"
        fi
        
        local day_clean=$((10#$day))
        echo "$day_clean $month_name $year, $hour_12:$minute:$second $ampm"
    else
        echo "$timestamp"
    fi
}

# ============================================================================
# PREREQUISITE CHECKING
# ============================================================================

# Check all prerequisites
check_prerequisites() {
    local silent=${1:-false}
    local required_commands=("jq" "curl" "sha1sum")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        if [[ "$silent" != "true" ]]; then
            print_error "Missing required commands: ${missing_commands[*]}"
            echo ""
            echo "Installation instructions:"
            echo "  • Ubuntu/Debian: sudo apt-get install jq curl coreutils"
            echo "  • CentOS/RHEL:   sudo yum install jq curl coreutils"
            echo "  • macOS:         brew install jq curl"
        fi
        return 1
    fi
    
    return 0
}

# ============================================================================
# CREDENTIALS MANAGEMENT
# ============================================================================

# Load credentials from file
load_credentials() {
    local creds_file="${1:-$CREDS_FILE}"
    
    if [[ ! -f "$creds_file" ]]; then
        print_error "Credentials file not found: $creds_file"
        print_info "Run setup_wizard.sh to configure credentials"
        return 1
    fi
    
    # Source the credentials file
    source "$creds_file" || {
        print_error "Failed to load credentials from $creds_file"
        return 1
    }
    
    # Validate required variables
    if [[ -z "${PRISM:-}" || -z "${USER:-}" || -z "${PASS:-}" ]]; then
        print_error "Invalid credentials file: missing PRISM, USER, or PASS"
        return 1
    fi
    
    return 0
}

# Test API connectivity
test_api_connection() {
    local prism="${1:-$PRISM}"
    local user="${2:-$USER}"
    local pass="${3:-$PASS}"
    local silent="${4:-false}"
    
    if [[ "$silent" != "true" ]]; then
        print_loading "Testing API connection to $prism..."
    fi
    
    # Test basic connectivity
    if ! curl -s --connect-timeout 10 --max-time 30 -k "https://$prism" >/dev/null 2>&1; then
        if [[ "$silent" != "true" ]]; then
            print_error "Cannot connect to https://$prism"
        fi
        return 1
    fi
    
    # Test API authentication
    local response
    response=$(curl -s --connect-timeout 10 --max-time 30 -k \
        -u "$user:$pass" \
        -X POST \
        "https://$prism/api/nutanix/v3/vms/list" \
        -H 'Content-Type: application/json' \
        -d '{"length":1}' 2>&1)
    
    if [[ $? -eq 0 ]] && echo "$response" | jq -e '.entities' >/dev/null 2>&1; then
        if [[ "$silent" != "true" ]]; then
            print_success "API connection successful"
        fi
        return 0
    else
        if [[ "$silent" != "true" ]]; then
            print_error "API authentication failed"
        fi
        return 1
    fi
}

# ============================================================================
# NUTANIX API FUNCTIONS
# ============================================================================

# Make API call with standard error handling
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local headers="${4:-}"
    
    local curl_cmd=()
    curl_cmd+=("curl" "-s" "-k" "-u" "$USER:$PASS")
    curl_cmd+=("-X" "$method")
    curl_cmd+=("https://$PRISM/api/nutanix/v3/$endpoint")
    
    if [[ -n "$headers" ]]; then
        curl_cmd+=("-H" "$headers")
    else
        curl_cmd+=("-H" "Content-Type: application/json")
    fi
    
    if [[ -n "$data" ]]; then
        curl_cmd+=("-d" "$data")
    fi
    
    "${curl_cmd[@]}"
}

# Fetch VMs from Prism Central
fetch_vms() {
    local length="${1:-1000}"
    local offset="${2:-0}"
    
    api_call "POST" "vms/list" \
        '{"length":'"$length"',"offset":'"$offset"'}'
}

# Fetch resources (generic)
fetch_resources() {
    local resource_type="$1"
    local length="${2:-1000}"
    local offset="${3:-0}"
    
    api_call "POST" "${resource_type}/list" \
        '{"kind":"'"$resource_type"'","length":'"$length"',"offset":'"$offset"'}'
}

# Export VM to OVA
export_vm() {
    local vm_uuid="$1"
    local ova_name="$2"
    local format="${3:-QCOW2}"
    
    api_call "POST" "vms/$vm_uuid/export" \
        '{"disk_file_format":"'"$format"'","name":"'"$ova_name"'"}'
}

# Get task status
get_task_status() {
    local task_uuid="$1"
    
    api_call "GET" "tasks/$task_uuid"
}

# Upload OVA (create entity)
create_ova_entity() {
    local ova_name="$1"
    local file_size="$2"
    local checksum="$3"
    
    api_call "POST" "ovas" \
        '{"name":"'"$ova_name"'","upload_length":'"$file_size"',"checksum":{"checksum_algorithm":"SHA_1","checksum_value":"'"$checksum"'"}}'
}

# Upload OVA chunk
upload_ova_chunk() {
    local ova_uuid="$1"
    local chunk_file="$2"
    local chunk_size="$3"
    local offset="$4"
    local checksum="$5"
    
    curl -s -k -u "$USER:$PASS" \
        -X PUT "https://$PRISM/api/nutanix/v3/ovas/$ova_uuid/chunks" \
        -H 'Content-Type: application/octet-stream' \
        -H "X-Nutanix-Checksum-Type:SHA_1" \
        -H "X-Nutanix-Checksum-Bytes:$checksum" \
        -H "X-Nutanix-Content-Length:$chunk_size" \
        -H "X-Nutanix-Upload-Offset:$offset" \
        --data-binary "@$chunk_file"
}

# Concatenate OVA chunks
concatenate_ova_chunks() {
    local ova_uuid="$1"
    
    api_call "POST" "ovas/$ova_uuid/chunks/concatenate"
}

# Get VM spec from OVA
get_vm_spec_from_ova() {
    local ova_uuid="$1"
    
    api_call "GET" "ovas/$ova_uuid/vm_spec"
}

# Create VM from spec
create_vm() {
    local vm_spec="$1"
    
    api_call "POST" "vms" "$vm_spec"
}

# Delete OVA
delete_ova() {
    local ova_uuid="$1"
    
    api_call "DELETE" "ovas/$ova_uuid"
}

# ============================================================================
# PROGRESS TRACKING
# ============================================================================

# Initialize progress tracking
declare -g -A PROGRESS_STATUS=()
declare -g -A PROGRESS_PERCENT=()
declare -g -A PROGRESS_DATA=()

# Update progress for a task
update_progress() {
    local task_id="$1"
    local status="$2"
    local percent="${3:-0}"
    local data="${4:-}"
    
    PROGRESS_STATUS["$task_id"]="$status"
    PROGRESS_PERCENT["$task_id"]="$percent"
    PROGRESS_DATA["$task_id"]="$data"
}

# Get progress for a task
get_progress() {
    local task_id="$1"
    
    local status="${PROGRESS_STATUS[$task_id]:-UNKNOWN}"
    local percent="${PROGRESS_PERCENT[$task_id]:-0}"
    local data="${PROGRESS_DATA[$task_id]:-}"
    
    echo "$status|$percent|$data"
}

# Clear progress tracking
clear_progress() {
    PROGRESS_STATUS=()
    PROGRESS_PERCENT=()
    PROGRESS_DATA=()
}

# ============================================================================
# TABLE DISPLAY FUNCTIONS
# ============================================================================

# Print a formatted table
print_table() {
    local -a headers=("$@")
    local -a rows=()
    local -a widths=()
    
    # Read rows from stdin
    while IFS= read -r line; do
        rows+=("$line")
    done
    
    # Calculate column widths
    for i in "${!headers[@]}"; do
        widths[i]=${#headers[i]}
    done
    
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r -a cols <<< "$row"
        for i in "${!cols[@]}"; do
            if [[ ${#cols[i]} -gt ${widths[i]:-0} ]]; then
                widths[i]=${#cols[i]}
            fi
        done
    done
    
    # Build format string
    local format=""
    local separator=""
    for i in "${!widths[@]}"; do
        format+="%-${widths[i]}s"
        separator+="$(printf '%*s' ${widths[i]} '' | tr ' ' '-')"
        if [[ $i -lt $((${#widths[@]} - 1)) ]]; then
            format+="  "
            separator+="--"
        fi
    done
    format+="\n"
    
    # Print table
    printf "${BOLD}${format}${NC}" "${headers[@]}"
    echo -e "${DIM}${separator}${NC}"
    
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r -a cols <<< "$row"
        printf "${format}" "${cols[@]}"
    done
}

# ============================================================================
# MENU SYSTEM
# ============================================================================

# Display paginated menu
display_paginated_menu() {
    local title="$1"
    local -a items=("${@:2}")
    local current_page="${CURRENT_PAGE:-1}"
    local items_per_page="${ITEMS_PER_PAGE:-$DEFAULT_ITEMS_PER_PAGE}"
    
    local total_items=${#items[@]}
    local total_pages=$(( (total_items + items_per_page - 1) / items_per_page ))
    local start_idx=$(( (current_page - 1) * items_per_page ))
    local end_idx=$(( start_idx + items_per_page - 1 ))
    
    if [[ $end_idx -ge $total_items ]]; then
        end_idx=$(( total_items - 1 ))
    fi
    
    clear
    print_menu_header "$title"
    
    if [[ $total_items -eq 0 ]]; then
        echo "No items available."
        return 1
    fi
    
    echo "Page $current_page of $total_pages | Showing $(( start_idx + 1 ))-$(( end_idx + 1 )) of $total_items items"
    echo ""
    
    local index=1
    for item in "${items[@]}"; do
        if [[ $index -ge $(( start_idx + 1 )) && $index -le $(( end_idx + 1 )) ]]; then
            printf "%3d) %s\n" "$index" "$item"
        fi
        ((index++))
    done
    
    echo ""
    echo "Navigation: n/N=Next, p/P=Previous, f/F=First, l/L=Last"
    echo "Actions: q/Q=Quit"
    echo ""
}

# Handle menu navigation
handle_menu_navigation() {
    local choice="$1"
    local total_pages="$2"
    local current_page_var="$3"
    
    case "$choice" in
        n|N)
            local current_page
            eval "current_page=\$$current_page_var"
            if [[ $current_page -lt $total_pages ]]; then
                eval "$current_page_var=\$((current_page + 1))"
            fi
            return 0
            ;;
        p|P)
            local current_page
            eval "current_page=\$$current_page_var"
            if [[ $current_page -gt 1 ]]; then
                eval "$current_page_var=\$((current_page - 1))"
            fi
            return 0
            ;;
        f|F)
            eval "$current_page_var=1"
            return 0
            ;;
        l|L)
            eval "$current_page_var=$total_pages"
            return 0
            ;;
        q|Q)
            return 2
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# FILE OPERATIONS
# ============================================================================

# Find restore points
find_restore_points() {
    local restore_dir="${1:-$SCRIPT_DIR/$RESTORE_POINTS_DIR}"
    local restore_points=()
    
    if [[ ! -d "$restore_dir" ]]; then
        return 1
    fi
    
    while IFS= read -r -d '' dir; do
        if [[ -f "$dir/vm_export_tasks.csv" ]]; then
            restore_points+=("$dir")
        fi
    done < <(find "$restore_dir" -maxdepth 1 -type d -name "vm-export-*" -print0 2>/dev/null)
    
    if [[ ${#restore_points[@]} -eq 0 ]]; then
        return 1
    fi
    
    printf '%s\n' "${restore_points[@]}" | sort -r
}

# Get restore point details
get_restore_point_details() {
    local restore_point="$1"
    local timestamp=$(basename "$restore_point" | sed 's/vm-export-//')
    local tasks_file="$restore_point/vm_export_tasks.csv"
    
    # Count VMs
    local vm_count=0
    if [[ -f "$tasks_file" ]]; then
        vm_count=$(tail -n +2 "$tasks_file" 2>/dev/null | wc -l)
    fi
    
    # Calculate total size
    local total_size=0
    if [[ -d "$restore_point" ]]; then
        while IFS= read -r -d '' file; do
            if [[ -f "$file" ]]; then
                local file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
                total_size=$((total_size + file_size))
            fi
        done < <(find "$restore_point" -name "*.ova" -print0 2>/dev/null)
    fi
    
    local readable_timestamp
    readable_timestamp=$(timestamp_to_readable "$timestamp")
    
    echo "$readable_timestamp|$vm_count|$total_size"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

# Initialize library
init_ui_lib() {
    local auto_load_creds="${1:-true}"
    
    # Check prerequisites
    if ! check_prerequisites true; then
        print_error "Prerequisites not met"
        return 1
    fi
    
    # Load credentials if requested
    if [[ "$auto_load_creds" == "true" ]]; then
        if ! load_credentials; then
            return 1
        fi
    fi
    
    # Create restore points directory if it doesn't exist
    if [[ ! -d "$SCRIPT_DIR/$RESTORE_POINTS_DIR" ]]; then
        mkdir -p "$SCRIPT_DIR/$RESTORE_POINTS_DIR"
    fi
    
    return 0
}

# Export library information
export_lib_info() {
    echo "UI Library v$UI_LIB_VERSION"
    echo "Script Directory: $SCRIPT_DIR"
    echo "Restore Points Directory: $SCRIPT_DIR/$RESTORE_POINTS_DIR"
    echo "Credentials File: $CREDS_FILE"
}

# ============================================================================
# CLEANUP
# ============================================================================

# Cleanup function
cleanup_ui_lib() {
    clear_progress
    unset PROGRESS_STATUS PROGRESS_PERCENT PROGRESS_DATA
}

# Set trap for cleanup
trap cleanup_ui_lib EXIT

# ============================================================================
# LIBRARY LOADED
# ============================================================================

# Print library loaded message (only if not in silent mode)
if [[ "${UI_LIB_SILENT:-}" != "true" ]]; then
    echo "UI Library v$UI_LIB_VERSION loaded"
fi