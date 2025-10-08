#!/usr/bin/env bash

##############################################################
# vm_custom_restore.sh
# ----------------------------------------------------------
# Interactive menu for custom VM restoration from OVA backups.
# Allows selection of restore points, OVA files, and custom
# configuration of VM name, subnet, and project for restoration.
#
# Workflow:
# 1. Select restore point (vm-export-* folder)
# 2. Select OVA file to restore
# 3. Configure VM name (default from CSV), subnet, and project
# 4. Upload OVA and restore VM with custom settings
##############################################################

set -eu

# Source the UI library
source "$(dirname "${BASH_SOURCE[0]}")/ui_lib.sh" || { echo "UI library not found or unreadable"; exit 1; }

# Load credentials
source .nutanix_creds || { echo "Credentials file not found or unreadable"; exit 1; }

# Prerequisites
command -v jq   >/dev/null || { echo "Please install jq (apt install jq)"; exit 1; }
command -v curl >/dev/null || { echo "Please install curl (apt install curl)"; exit 1; }
command -v sha1sum >/dev/null || { echo "Please install sha1sum"; exit 1; }

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL=5
CHUNK_SIZE=$((100 * 1024 * 1024))  # 100MB chunks for upload

# Global variables for resource maps and selections
declare -g -A SUBNET_MAP=()
declare -g -A PROJECT_MAP=()
declare -g -a SELECTED_SUBNETS=()
declare -g -a SELECTED_SUBNET_UUIDS=()

# Find available restore points
find_restore_points() {
    local restore_points=()
    while IFS= read -r -d '' dir; do
        if [[ -f "$dir/vm_export_tasks.csv" ]]; then
            restore_points+=("$dir")
        fi
    done < <(find "$SCRIPT_DIR/restore-points" -maxdepth 1 -type d -name "vm-export-*" -print0 2>/dev/null)
    
    if [[ ${#restore_points[@]} -eq 0 ]]; then
        echo "No restore points found. Please run vm_export_menu.sh first to create backups."
        exit 1
    fi
    
    printf '%s\n' "${restore_points[@]}" | sort -r  # Most recent first
}

# Display restore point selection menu
display_restore_points() {
    clear
    echo "==========================================="
    echo "     Custom VM Restore - Select Backup"
    echo "==========================================="
    echo ""
    
    local restore_points
    mapfile -t restore_points < <(find_restore_points)
    
    echo "Available restore points:"
    echo ""
    
    for i in "${!restore_points[@]}"; do
        local dir="${restore_points[i]}"
        local timestamp=$(basename "$dir" | sed 's/vm-export-//')
        local vm_count=$(tail -n +2 "$dir/vm_export_tasks.csv" 2>/dev/null | wc -l)
        
        # Calculate total size
        local total_size=0
        if [[ -d "$dir" ]]; then
            while IFS= read -r -d '' file; do
                if [[ -f "$file" ]]; then
                    local file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
                    total_size=$((total_size + file_size))
                fi
            done < <(find "$dir" -name "*.ova" -print0 2>/dev/null)
        fi
        
        # Convert bytes to human readable format
        local size_display=""
        if [[ $total_size -eq 0 ]]; then
            size_display="0MB"
        elif [[ $total_size -lt $((1024 * 1024 * 1024)) ]]; then
            size_display="$((total_size / 1024 / 1024))MB"
        else
            size_display="$((total_size / 1024 / 1024 / 1024))GB"
        fi
        
        # Convert timestamp to readable format
        local readable_timestamp=""
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
            readable_timestamp="$day_clean $month_name $year, $hour_12:$minute:$second $ampm"
        else
            readable_timestamp="$timestamp"
        fi
        
        printf "%2d) %s (%d VMs, %s)\n" "$((i+1))" "$readable_timestamp" "$vm_count" "$size_display"
    done
    
    echo ""
    echo "Actions:"
    echo "  [number] - Select restore point"
    echo "  q        - Quit"
    echo ""
}

# Load all VM data and build unique VM list with restore point counts
load_all_vm_data() {
    declare -g -a all_vm_data=()
    declare -g -a unique_vms=()
    declare -g -A vm_restore_points=()
    
    local restore_points
    mapfile -t restore_points < <(find_restore_points)
    
    for restore_point in "${restore_points[@]}"; do
        local tasks_file="$restore_point/vm_export_tasks.csv"
        local backup_date=$(basename "$restore_point" | sed 's/vm-export-//')
        
        if [[ ! -f "$tasks_file" ]]; then
            continue
        fi
        
        while IFS=',' read -r vm_name vm_uuid project_name task_uuid ova_name; do
            [[ "$vm_name" == "VM_NAME" ]] && continue
            
            # Check if OVA file exists
            local ova_file="$restore_point/${ova_name}.ova"
            if [[ -f "$ova_file" ]]; then
                # Store all VM data for later lookup
                # Format: project|vm_name|vm_uuid|ova_name|ova_file|backup_date|restore_point
                all_vm_data+=("$project_name|$vm_name|$vm_uuid|$ova_name|$ova_file|$backup_date|$restore_point")
                
                # Build unique VM identifier
                local vm_key="$project_name|$vm_name"
                
                # Add to restore points mapping
                if [[ -z "${vm_restore_points[$vm_key]:-}" ]]; then
                    vm_restore_points["$vm_key"]="$backup_date:$restore_point:$ova_file"
                else
                    vm_restore_points["$vm_key"]+=";$backup_date:$restore_point:$ova_file"
                fi
            fi
        done < "$tasks_file"
    done
    
    if [[ ${#all_vm_data[@]} -eq 0 ]]; then
        echo "No valid VM backup files found in any restore points."
        return 1
    fi
    
    # Build unique VMs list sorted by project then VM name
    for vm_key in "${!vm_restore_points[@]}"; do
        unique_vms+=("$vm_key")
    done
    
    # Sort unique VMs by project then VM name
    local temp_file=$(mktemp)
    printf '%s\n' "${unique_vms[@]}" | sort -t'|' -k1,1 -k2,2 > "$temp_file"
    
    unique_vms=()
    while IFS= read -r line; do
        unique_vms+=("$line")
    done < "$temp_file"
    
    rm -f "$temp_file"
}

# Display unique VMs menu with pagination
display_unique_vms_menu() {
    clear
    echo "==========================================="
    echo "     Custom VM Restore - Select VM"
    echo "==========================================="
    echo ""
    
    # Calculate pagination
    local total_items=${#unique_vms[@]}
    local start_idx=$(( (current_page - 1) * items_per_page ))
    local end_idx=$(( start_idx + items_per_page - 1 ))
    if [[ $end_idx -ge $total_items ]]; then
        end_idx=$(( total_items - 1 ))
    fi
    
    echo "Available VMs (sorted by project, then name):"
    echo "Page $current_page of $total_pages | Showing $(( start_idx + 1 ))-$(( end_idx + 1 )) of $total_items VMs"
    echo ""
    
    local current_project=""
    local index=1
    
    for vm_key in "${unique_vms[@]}"; do
        IFS='|' read -r project name <<< "$vm_key"
        
        # Only display items for current page
        if [[ $index -ge $(( start_idx + 1 )) && $index -le $(( end_idx + 1 )) ]]; then
            if [[ "$project" != "$current_project" ]]; then
                if [[ -n "$current_project" ]]; then
                    echo ""
                fi
                echo "Project: $project"
                echo "----------------------------------------"
                current_project="$project"
            fi
            
            # Count restore points for this VM
            local restore_point_data="${vm_restore_points[$vm_key]}"
            local restore_count=$(echo "$restore_point_data" | tr ';' '\n' | wc -l)
            
            printf "%3d) %-25s (%d restore points)\n" "$index" "$name" "$restore_count"
        fi
        ((index++))
    done
    
    echo ""
    echo "Navigation:"
    echo "  n/N       - Next page"
    echo "  p/P       - Previous page"
    echo "  f/F       - First page"
    echo "  l/L       - Last page"
    echo ""
    echo "Actions:"
    echo "  [number]  - Select VM to see restore points"
    echo "  q         - Quit"
    echo ""
}

# Display restore points for selected VM
display_vm_restore_points() {
    local vm_key="$1"
    IFS='|' read -r project vm_name <<< "$vm_key"
    
    clear
    echo "==========================================="
    echo "   Restore Points for: $vm_name"
    echo "==========================================="
    echo ""
    echo "Project: $project"
    echo ""
    
    # Parse restore points and sort by date (latest first)
    local restore_point_data="${vm_restore_points[$vm_key]}"
    local -a restore_entries=()
    
    IFS=';' read -ra entries <<< "$restore_point_data"
    for entry in "${entries[@]}"; do
        restore_entries+=("$entry")
    done
    
    # Sort by backup date (latest first)
    local temp_file=$(mktemp)
    printf '%s\n' "${restore_entries[@]}" | sort -t':' -k1,1r > "$temp_file"
    
    restore_entries=()
    while IFS= read -r line; do
        restore_entries+=("$line")
    done < "$temp_file"
    rm -f "$temp_file"
    
    echo "Available restore points (latest first):"
    echo ""
    
    for i in "${!restore_entries[@]}"; do
        local entry="${restore_entries[i]}"
        IFS=':' read -r backup_date restore_point ova_file <<< "$entry"
        
        # Convert backup date to readable format
        local readable_date=""
        if [[ $backup_date =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
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
            readable_date="$day_clean $month_name $year, $hour_12:$minute:$second $ampm"
        else
            readable_date="$backup_date"
        fi
        
        # Show file size
        local file_size=$(stat -c%s "$ova_file" 2>/dev/null || echo "0")
        local size_mb=$(( file_size / 1024 / 1024 ))
        
        printf "%2d) %s (%dMB)\n" "$((i+1))" "$readable_date" "$size_mb"
    done
    
    echo ""
    echo "Actions:"
    echo "  [number] - Select restore point to restore"
    echo "  b        - Back to VM selection"
    echo "  q        - Quit"
    echo ""
    
    # Store current restore entries for selection
    declare -g -a current_restore_entries=("${restore_entries[@]}")
}

# Build resource maps for subnets and projects
build_resource_maps() {
    echo "Loading available subnets and projects..."
    
    # Build subnets map using a safer parsing method
    local subnets_json=$(curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM:9440/api/nutanix/v3/subnets/list" \
        -H 'Content-Type: application/json' \
        -d '{"kind":"subnet","length":1000,"offset":0}')
    
    if [[ -n "$subnets_json" ]] && jq -e '.entities' <<< "$subnets_json" >/dev/null 2>&1; then
        # Use jq to safely parse and handle names with spaces
        local temp_file=$(mktemp)
        jq -r '.entities[]? | select(.status.name != null and .metadata.uuid != null) | "\(.status.name)|||\(.metadata.uuid)"' <<< "$subnets_json" > "$temp_file"
        
        while IFS='|||' read -r name uuid; do
            # Clean any residual delimiters from UUID
            uuid=$(echo "$uuid" | sed 's/^|*//g')
            [[ -n "$name" && -n "$uuid" ]] && SUBNET_MAP["$name"]="$uuid"
        done < "$temp_file"
        
        rm -f "$temp_file"
    fi
    
    # Build projects map using the same safe parsing method
    local projects_json=$(curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM:9440/api/nutanix/v3/projects/list" \
        -H 'Content-Type: application/json' \
        -d '{"kind":"project","length":100,"offset":0}')
    
    if [[ -n "$projects_json" ]] && jq -e '.entities' <<< "$projects_json" >/dev/null 2>&1; then
        # Use jq to safely parse and handle names with spaces
        local temp_file=$(mktemp)
        jq -r '.entities[]? | select(.status.name != null and .metadata.uuid != null) | "\(.status.name)|||\(.metadata.uuid)"' <<< "$projects_json" > "$temp_file"
        
        while IFS='|||' read -r name uuid; do
            # Clean any residual delimiters from UUID
            uuid=$(echo "$uuid" | sed 's/^|*//g')
            [[ -n "$name" && -n "$uuid" ]] && PROJECT_MAP["$name"]="$uuid"
        done < "$temp_file"
        
        rm -f "$temp_file"
    fi
    
    echo "Found ${#SUBNET_MAP[@]} subnets and ${#PROJECT_MAP[@]} projects"
    echo ""
}

# Select subnets from available options (multi-select)
select_subnet() {
    clear
    echo "==========================================="
    echo "        Select Subnets for VM"
    echo "==========================================="
    echo ""
    
    if [[ ${#SUBNET_MAP[@]} -eq 0 ]]; then
        echo "No subnets available. Using original subnets from OVA."
        echo ""
        read -p "Press Enter to continue..."
        echo ""
        return
    fi
    
    # Use a safer method to handle names with spaces
    local temp_file=$(mktemp)
    printf '%s\n' "${!SUBNET_MAP[@]}" | sort > "$temp_file"
    
    local -a subnet_names=()
    while IFS= read -r subnet_name; do
        subnet_names+=("$subnet_name")
    done < "$temp_file"
    rm -f "$temp_file"
    
    # Clear any previous selections and initialize tracking
    SELECTED_SUBNETS=()
    SELECTED_SUBNET_UUIDS=()
    declare -A subnet_selected=()
    
    while true; do
        clear
        echo "==========================================="
        echo "        Select Subnets for VM"
        echo "==========================================="
        echo ""
        echo "Available subnets:"
        echo ""
        
        for i in "${!subnet_names[@]}"; do
            local status=""
            if [[ -n "${subnet_selected[$((i+1))]:-}" ]]; then
                status="[SELECTED]"
            fi
            printf "%2d) %-30s %s\n" "$((i+1))" "${subnet_names[i]}" "$status"
        done
        
        echo ""
        echo "Actions:"
        echo "  [number] - Toggle subnet selection"
        echo "  a        - Select all subnets"
        echo "  c        - Clear all selections"
        echo "  o        - Use original subnets from OVA"
        echo "  done     - Finish subnet selection"
        echo "  b        - Back"
        echo ""
        echo "Selected: ${#SELECTED_SUBNETS[@]} subnets"
        echo ""
        
        read -p "Enter choice: " subnet_choice
        
        case "$subnet_choice" in
            [0-9]*)
                if [[ "$subnet_choice" -ge 1 && "$subnet_choice" -le ${#subnet_names[@]} ]]; then
                    if [[ -n "${subnet_selected[$subnet_choice]:-}" ]]; then
                        # Remove from selection
                        unset subnet_selected[$subnet_choice]
                        local subnet_name="${subnet_names[$((subnet_choice-1))]}"
                        # Remove from arrays
                        local -a new_subnets=()
                        local -a new_uuids=()
                        for j in "${!SELECTED_SUBNETS[@]}"; do
                            if [[ "${SELECTED_SUBNETS[j]}" != "$subnet_name" ]]; then
                                new_subnets+=("${SELECTED_SUBNETS[j]}")
                                new_uuids+=("${SELECTED_SUBNET_UUIDS[j]}")
                            fi
                        done
                        SELECTED_SUBNETS=("${new_subnets[@]}")
                        SELECTED_SUBNET_UUIDS=("${new_uuids[@]}")
                    else
                        # Add to selection
                        subnet_selected[$subnet_choice]=1
                        local subnet_name="${subnet_names[$((subnet_choice-1))]}"
                        SELECTED_SUBNETS+=("$subnet_name")
                        SELECTED_SUBNET_UUIDS+=("${SUBNET_MAP[$subnet_name]}")
                    fi
                else
                    echo "Invalid selection. Press Enter to continue..."
                    read
                fi
                ;;
            a|A)
                # Select all
                subnet_selected=()
                SELECTED_SUBNETS=()
                SELECTED_SUBNET_UUIDS=()
                for i in "${!subnet_names[@]}"; do
                    subnet_selected[$((i+1))]=1
                    SELECTED_SUBNETS+=("${subnet_names[i]}")
                    SELECTED_SUBNET_UUIDS+=("${SUBNET_MAP[${subnet_names[i]}]}")
                done
                ;;
            c|C)
                # Clear all
                subnet_selected=()
                SELECTED_SUBNETS=()
                SELECTED_SUBNET_UUIDS=()
                ;;
            o|O)
                # Use original subnets
                SELECTED_SUBNETS=()
                SELECTED_SUBNET_UUIDS=()
                echo "Will use original subnets from OVA"
                sleep 1
                return 0
                ;;
            done|DONE)
                if [[ ${#SELECTED_SUBNETS[@]} -eq 0 ]]; then
                    echo "No subnets selected. Will use original subnets from OVA."
                    sleep 1
                    return 0
                else
                    echo "Selected ${#SELECTED_SUBNETS[@]} subnets:"
                    for subnet in "${SELECTED_SUBNETS[@]}"; do
                        echo "  - $subnet"
                    done
                    sleep 2
                    return 0
                fi
                ;;
            b|B)
                return 1
                ;;
            *)
                echo "Invalid choice. Press Enter to continue..."
                read
                ;;
        esac
    done
}

# Select project from available options
select_project() {
    clear
    echo "==========================================="
    echo "        Select Project for VM"
    echo "==========================================="
    echo ""
    
    if [[ ${#PROJECT_MAP[@]} -eq 0 ]]; then
        echo "No projects available. Using original project."
        echo ""
        read -p "Press Enter to continue..."
        echo ""
        return
    fi
    
    echo "Available projects:"
    echo ""
    
    # Use a safer method to handle names with spaces
    local temp_file=$(mktemp)
    printf '%s\n' "${!PROJECT_MAP[@]}" | sort > "$temp_file"
    
    local -a project_names=()
    while IFS= read -r project_name; do
        project_names+=("$project_name")
    done < "$temp_file"
    rm -f "$temp_file"
    
    for i in "${!project_names[@]}"; do
        printf "%2d) %s\n" "$((i+1))" "${project_names[i]}"
    done
    
    echo ""
    echo "Actions:"
    echo "  [number] - Select project"
    echo "  o        - Use original project from backup"
    echo "  b        - Back"
    echo ""
    
    while true; do
        read -p "Enter choice: " project_choice
        
        if [[ "$project_choice" =~ ^[0-9]+$ ]] && [[ "$project_choice" -ge 1 && "$project_choice" -le ${#project_names[@]} ]]; then
            SELECTED_PROJECT="${project_names[$((project_choice-1))]}"
            SELECTED_PROJECT_UUID="${PROJECT_MAP[$SELECTED_PROJECT]}"
            echo "Selected project: $SELECTED_PROJECT"
            break
        elif [[ "$project_choice" == "o" || "$project_choice" == "O" ]]; then
            SELECTED_PROJECT=""
            SELECTED_PROJECT_UUID=""
            echo "Will use original project from backup"
            break
        elif [[ "$project_choice" == "b" || "$project_choice" == "B" ]]; then
            return 1
        else
            echo "Invalid choice. Please try again."
        fi
    done
    
    sleep 1
}

# Configure VM restoration settings
configure_vm_restore() {
    local original_name="$1"
    local original_project="$2"
    
    clear
    echo "==========================================="
    echo "      Configure VM Restoration"
    echo "==========================================="
    echo ""
    echo "Original VM: $original_name (Project: $original_project)"
    echo ""
    
    # Get custom VM name
    echo "VM Name Configuration:"
    echo "Default: $original_name"
    echo ""
    read -p "Enter new VM name (or press Enter for default): " custom_name
    
    if [[ -z "$custom_name" ]]; then
        SELECTED_VM_NAME="$original_name"
    else
        SELECTED_VM_NAME="$custom_name"
    fi
    
    echo ""
    echo "Selected VM name: $SELECTED_VM_NAME"
    echo ""
    
    # Select subnets
    echo "Configuring network subnets..."
    if ! select_subnet; then
        return 1
    fi
    
    # Select project
    echo "Configuring project..."
    if ! select_project; then
        return 1
    fi
    
    # Show configuration summary
    clear
    echo "==========================================="
    echo "      Restoration Configuration Summary"
    echo "==========================================="
    echo ""
    echo "VM Name:     $SELECTED_VM_NAME"
    if [[ ${#SELECTED_SUBNETS[@]} -gt 0 ]]; then
        echo "Subnets:     ${SELECTED_SUBNETS[0]}"
        for ((i=1; i<${#SELECTED_SUBNETS[@]}; i++)); do
            echo "             ${SELECTED_SUBNETS[i]}"
        done
    else
        echo "Subnets:     Original from OVA"
    fi
    echo "Project:     ${SELECTED_PROJECT:-"Original from backup ($original_project)"}"
    echo ""
    
    read -p "Proceed with restoration? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy] ]]; then
        return 0
    else
        return 1
    fi
}

# Progress table functions (copied from vm_restore_menu.sh)
declare -g -A RESTORE_VM_DATA=()
declare -g -A RESTORE_STATUS=()
declare -g -A RESTORE_PROGRESS=()

# Print formatted table from internal arrays
print_restore_table() {
    local headers cols maxlen fmt_row dash_line i
    local rows=()
    
    headers=( "VM_NAME" "PROJECT" "OVA_FILE" "STATUS" "PROGRESS" )
    
    # Build rows from internal arrays
    for vm_name in "${!RESTORE_VM_DATA[@]}"; do
        IFS='|' read -r project ova_name <<< "${RESTORE_VM_DATA[$vm_name]}"
        local status="${RESTORE_STATUS[$vm_name]}"
        local progress="${RESTORE_PROGRESS[$vm_name]}%"
        rows+=("$vm_name"$'\t'"$project"$'\t'"$ova_name"$'\t'"$status"$'\t'"$progress")
    done
    
    # Calculate column widths
    for i in "${!headers[@]}"; do
        maxlen[i]=${#headers[i]}
    done
    
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r -a cols <<<"$row"
        for i in "${!cols[@]}"; do
            (( ${#cols[i]} > maxlen[i] )) && maxlen[i]=${#cols[i]}
        done
    done
    
    # Build format string
    fmt_row=""
    for i in "${!maxlen[@]}"; do
        fmt_row+="%-${maxlen[i]}s"
        (( i < ${#maxlen[@]}-1 )) && fmt_row+="  "
    done
    fmt_row+="\n"
    
    dash_line="$(printf "$fmt_row" "${maxlen[@]}" | sed 's/./-/g')"
    
    clear
    echo "Restore Progress:"
    echo ""
    printf "$fmt_row" "${headers[@]}"
    printf "%s\n" "$dash_line"
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r -a cols <<<"$row"
        printf "$fmt_row" "${cols[@]}"
    done
    echo ""
}

# Update restore status in internal arrays
update_restore_status() {
    local vm_name="$1"
    local status="$2"
    local progress="$3"
    
    RESTORE_STATUS["$vm_name"]="$status"
    RESTORE_PROGRESS["$vm_name"]="$progress"
    
    # Only refresh display if not in debug mode
    if [[ -z "${DEBUG_MODE:-}" ]]; then
        print_restore_table >&2
        sleep 0.1
    fi
}

# Upload OVA file to Prism Central with progress table
upload_ova() {
    local ova_file="$1"
    local ova_name="$2"
    local vm_name="$3"
    
    local filesize=$(stat -c%s "$ova_file")
    
    # Update status: Generating checksum
    update_restore_status "$vm_name" "GENERATING_SHA1" 0
    
    local full_cs=$(sha1sum "$ova_file" | cut -d' ' -f1)
    
    # Update status: Creating entity
    update_restore_status "$vm_name" "CREATING_ENTITY" 0
    
    # Create OVA entity
    local create_resp=$(curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM:9440/api/nutanix/v3/ovas" \
        -H 'Content-Type: application/json' \
        -d '{"name":"'"$ova_name"'","upload_length":'"$filesize"',"checksum":{"checksum_algorithm":"SHA_1","checksum_value":"'"$full_cs"'"}}')
    
    local task_uuid=$(jq -r '.task_uuid // empty' <<< "$create_resp")
    if [[ -z "$task_uuid" ]]; then
        update_restore_status "$vm_name" "FAILED" 0
        return 1
    fi
    
    # Wait for OVA UUID
    local ova_uuid=""
    while [[ -z "$ova_uuid" ]]; do
        local task_json=$(curl -s -k -u "$USER:$PASS" \
            -X GET "https://$PRISM:9440/api/nutanix/v3/tasks/$task_uuid" \
            -H 'Accept: application/json')
        ova_uuid=$(jq -r '.entity_reference_list[0].uuid // empty' <<< "$task_json")
        
        if [[ "$(jq -r '.status' <<< "$task_json")" == "FAILED" ]]; then
            update_restore_status "$vm_name" "FAILED" 0
            return 1
        fi
        sleep 1
    done
    
    # Update status: Uploading
    update_restore_status "$vm_name" "UPLOADING" 0
    
    # Upload file in chunks with progress
    for (( off=0; off<filesize; off+=CHUNK_SIZE )); do
        local bytes=$(( filesize - off < CHUNK_SIZE ? filesize - off : CHUNK_SIZE ))
        local tmpf=$(mktemp)
        
        dd if="$ova_file" of="$tmpf" bs=$CHUNK_SIZE skip=$((off/CHUNK_SIZE)) count=1 status=none 2>/dev/null
        local cs=$(sha1sum "$tmpf" | cut -d' ' -f1)
        
        curl -s -k -u "$USER:$PASS" \
            -X PUT "https://$PRISM:9440/api/nutanix/v3/ovas/$ova_uuid/chunks" \
            -H 'Content-Type: application/octet-stream' \
            -H "X-Nutanix-Checksum-Type:SHA_1" \
            -H "X-Nutanix-Checksum-Bytes:$cs" \
            -H "X-Nutanix-Content-Length:$bytes" \
            -H "X-Nutanix-Upload-Offset:$off" \
            --data-binary @"$tmpf" >/dev/null
        
        rm -f "$tmpf"
        
        local pct=$(( (off + bytes) * 100 / filesize ))
        update_restore_status "$vm_name" "UPLOADING" "$pct"
    done
    
    # Update status: Validating
    update_restore_status "$vm_name" "VALIDATING" 0
    
    # Concatenate chunks
    local concat_resp=$(curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM:9440/api/nutanix/v3/ovas/$ova_uuid/chunks/concatenate" \
        -H 'Accept: application/json')
    
    local concat_task=$(jq -r '.task_uuid // empty' <<< "$concat_resp")
    if [[ -z "$concat_task" ]]; then
        update_restore_status "$vm_name" "FAILED" 0
        return 1
    fi
    
    # Monitor validation
    local max_wait_time=600  # 10 minutes max
    local elapsed_time=0
    
    while :; do
        local task_json=$(curl -s -k -u "$USER:$PASS" \
            -X GET "https://$PRISM:9440/api/nutanix/v3/tasks/$concat_task" \
            -H 'Accept: application/json')
        local status_now=$(jq -r '.status' <<< "$task_json")
        local pc=$(jq -r '.percentage_complete // 0' <<< "$task_json")
        
        update_restore_status "$vm_name" "VALIDATING" "$pc"
        
        if [[ "$status_now" == "SUCCEEDED" ]]; then
            update_restore_status "$vm_name" "UPLOAD_COMPLETED" 100
            break
        elif [[ "$status_now" == "FAILED" ]]; then
            update_restore_status "$vm_name" "FAILED" 0
            return 1
        elif [[ "$status_now" == "RUNNING" || "$status_now" == "QUEUED" ]]; then
            # Continue monitoring
            :
        else
            echo "Unexpected validation status: $status_now" >&2
        fi
        
        # Check for timeout
        if [[ $elapsed_time -gt $max_wait_time ]]; then
            echo "Timeout waiting for validation to complete" >&2
            update_restore_status "$vm_name" "FAILED" 0
            return 1
        fi
        
        sleep $POLL_INTERVAL
        elapsed_time=$((elapsed_time + POLL_INTERVAL))
    done
    
    echo "$ova_uuid"  # Return OVA UUID
}

# Restore VM from uploaded OVA with progress table
restore_vm() {
    local vm_name="$1"
    local original_project="$2"
    local ova_uuid="$3"
    
    update_restore_status "$vm_name" "RESTORING" 0
    
    # Fetch VM spec from OVA
    local vm_spec_json=$(curl -s -k -u "$USER:$PASS" \
        -X GET "https://$PRISM:9440/api/nutanix/v3/ovas/$ova_uuid/vm_spec" \
        -H 'Content-Type: application/json')
    
    if [[ -z "$vm_spec_json" ]] || ! jq -e '.vm_spec.spec' <<< "$vm_spec_json" >/dev/null 2>&1; then
        echo "DEBUG: Failed to fetch VM spec from OVA $ova_uuid" >&2
        echo "DEBUG: VM spec response: $vm_spec_json" >&2
        update_restore_status "$vm_name" "FAILED" 0
        return 1
    fi
    
    local spec=$(jq '.vm_spec.spec' <<< "$vm_spec_json")
    
    # Update subnets if selected
    if [[ ${#SELECTED_SUBNET_UUIDS[@]} -gt 0 ]]; then
        local updated_nics=()
        local subnet_index=0
        
        # Create NICs for each selected subnet
        for subnet_uuid in "${SELECTED_SUBNET_UUIDS[@]}"; do
            # Get the first NIC as a template
            local template_nic=$(jq -c '.resources.nic_list[0] // {}' <<< "$spec")
            
            if [[ "$template_nic" != "{}" ]]; then
                # Update the subnet reference
                local new_nic=$(jq --arg uuid "$subnet_uuid" '.subnet_reference.uuid = $uuid' <<< "$template_nic")
                updated_nics+=("$new_nic")
            else
                # Create a basic NIC if none exists
                local new_nic=$(jq -n --arg uuid "$subnet_uuid" '{
                    "nic_type": "NORMAL_NIC",
                    "subnet_reference": {
                        "kind": "subnet",
                        "uuid": $uuid
                    }
                }')
                updated_nics+=("$new_nic")
            fi
        done
        
        if [[ ${#updated_nics[@]} -gt 0 ]]; then
            local nic_array=$(printf '%s\n' "${updated_nics[@]}" | jq -s '.')
            spec=$(jq --argjson nics "$nic_array" '.resources.nic_list = $nics' <<< "$spec")
        fi
    fi
    
    # Determine project UUID
    local proj_uuid=""
    if [[ -n "$SELECTED_PROJECT_UUID" ]]; then
        proj_uuid="$SELECTED_PROJECT_UUID"
    else
        proj_uuid="${PROJECT_MAP[$original_project]:-}"
        if [[ -z "$proj_uuid" ]]; then
            update_restore_status "$vm_name" "FAILED" 0
            return 1
        fi
    fi
    
    # Create VM payload
    local payload=$(jq -n \
        --arg name "$vm_name" \
        --arg proj_uuid "$proj_uuid" \
        --argjson spec "$spec" \
        '{
            metadata: {
                kind: "vm",
                name: $name,
                project_reference: { kind: "project", uuid: $proj_uuid },
                spec_version: 0
            },
            spec: ($spec | .name = $name)
        }')
    
    # Submit VM creation
    local create_resp=$(curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM:9440/api/nutanix/v3/vms" \
        -H 'Content-Type: application/json' \
        -d "$payload")
    
    local new_vm_uuid=$(jq -r '.metadata.uuid // empty' <<< "$create_resp")
    local task_id=$(jq -r '.status.execution_context.task_uuid // empty' <<< "$create_resp")
    
    if [[ -z "$new_vm_uuid" || -z "$task_id" ]]; then
        echo "DEBUG: VM creation failed for $vm_name" >&2
        echo "DEBUG: new_vm_uuid='$new_vm_uuid'" >&2
        echo "DEBUG: task_id='$task_id'" >&2
        echo "DEBUG: Response: $create_resp" >&2
        echo "DEBUG: Payload: $payload" >&2
        update_restore_status "$vm_name" "FAILED" 0
        return 1
    fi
    
    # Monitor restoration progress
    while true; do
        local task_json=$(curl -s -k -u "$USER:$PASS" \
            -X GET "https://$PRISM:9440/api/nutanix/v3/tasks/$task_id" \
            -H 'Accept: application/json')
        local status_now=$(jq -r '.status' <<< "$task_json")
        local pc=$(jq -r '.percentage_complete // 0' <<< "$task_json")
        
        update_restore_status "$vm_name" "RESTORING" "$pc"
        
        if [[ "$status_now" == "SUCCEEDED" ]]; then
            update_restore_status "$vm_name" "COMPLETED" 100
            break
        elif [[ "$status_now" == "FAILED" ]]; then
            update_restore_status "$vm_name" "FAILED" 0
            return 1
        fi
        sleep $POLL_INTERVAL
    done
    
    echo "$new_vm_uuid"
}

# Main restoration workflow
perform_custom_restore() {
    local vm_key="$1"
    local restore_index="$2"
    
    IFS='|' read -r original_project original_name <<< "$vm_key"
    
    local entry="${current_restore_entries[$((restore_index-1))]}"
    IFS=':' read -r backup_date restore_point ova_file <<< "$entry"
    
    # Extract other details from the full data
    local uuid="" ova_name=""
    for vm_data in "${all_vm_data[@]}"; do
        IFS='|' read -r proj name vm_uuid ova_nm ova_fl bk_date rst_pt <<< "$vm_data"
        if [[ "$proj" == "$original_project" && "$name" == "$original_name" && "$bk_date" == "$backup_date" ]]; then
            uuid="$vm_uuid"
            ova_name="$ova_nm"
            break
        fi
    done
    
    # Configure restoration settings
    if ! configure_vm_restore "$original_name" "$original_project"; then
        echo "Restoration cancelled."
        return
    fi
    
    # Initialize progress table for single VM
    RESTORE_VM_DATA["$SELECTED_VM_NAME"]="$original_project|$ova_name"
    RESTORE_STATUS["$SELECTED_VM_NAME"]="PENDING"
    RESTORE_PROGRESS["$SELECTED_VM_NAME"]="0"
    
    # Don't enable debug mode yet - let progress table work during upload
    # export DEBUG_MODE=1
    
    # Display initial progress table
    print_restore_table
    
    # Upload OVA (use UUID as name, not with .ova extension)
    local ova_uuid
    if ova_uuid=$(upload_ova "$ova_file" "$ova_name" "$SELECTED_VM_NAME"); then
        if [[ -n "$ova_uuid" ]]; then
            # Enable debug mode before restore to see any errors
            export DEBUG_MODE=1
            
            # Restore VM
            local new_vm_uuid
            if new_vm_uuid=$(restore_vm "$SELECTED_VM_NAME" "$original_project" "$ova_uuid"); then
                echo ""
                echo "🎉 Custom restoration completed successfully!"
                echo ""
                echo "Restored VM Details:"
                echo "  Name:     $SELECTED_VM_NAME"
                echo "  UUID:     $new_vm_uuid"
                echo "  Project:  ${SELECTED_PROJECT:-$original_project}"
                if [[ ${#SELECTED_SUBNETS[@]} -gt 0 ]]; then
                    echo "  Subnets:  ${SELECTED_SUBNETS[0]}"
                    for ((i=1; i<${#SELECTED_SUBNETS[@]}; i++)); do
                        echo "            ${SELECTED_SUBNETS[i]}"
                    done
                else
                    echo "  Subnets:  Original"
                fi
                
                # Ask about OVA cleanup
                echo ""
                read -p "Delete uploaded OVA from Prism Central? (y/N): " delete_choice
                if [[ "$delete_choice" =~ ^[Yy] ]]; then
                    echo "→ Deleting uploaded OVA..."
                    curl -s -k -u "$USER:$PASS" \
                        -X DELETE "https://$PRISM:9440/api/nutanix/v3/ovas/$ova_uuid" \
                        -H 'Content-Type: application/json' >/dev/null
                    echo "✅ OVA deleted from Prism Central"
                fi
            else
                echo "Restoration failed. OVA remains uploaded (UUID: $ova_uuid)"
            fi
        else
            echo "Upload failed - no OVA UUID returned"
        fi
    else
        echo "Upload failed"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Main execution
main() {
    # Load all VM data from all restore points
    if ! load_all_vm_data; then
        exit 1
    fi
    
    # Build resource maps early so they're available for selection
    build_resource_maps
    
    # Initialize pagination
    items_per_page=15
    current_page=1
    total_pages=$(( (${#unique_vms[@]} + items_per_page - 1) / items_per_page ))
    
    while true; do
        display_unique_vms_menu
        read -p "Enter choice: " choice
        
        case "$choice" in
            [0-9]*)
                if [[ "$choice" -ge 1 && "$choice" -le ${#unique_vms[@]} ]]; then
                    local selected_vm_key="${unique_vms[$((choice-1))]}"
                    
                    # Show restore points for selected VM
                    while true; do
                        display_vm_restore_points "$selected_vm_key"
                        read -p "Enter choice: " restore_choice
                        
                        case "$restore_choice" in
                            [0-9]*)
                                if [[ "$restore_choice" -ge 1 && "$restore_choice" -le ${#current_restore_entries[@]} ]]; then
                                    perform_custom_restore "$selected_vm_key" "$restore_choice"
                                else
                                    echo "Invalid selection. Press Enter to continue..."
                                    read
                                fi
                                ;;
                            b|B)
                                break
                                ;;
                            q|Q)
                                echo "Exiting..."
                                exit 0
                                ;;
                            *)
                                echo "Invalid choice. Press Enter to continue..."
                                read
                                ;;
                        esac
                    done
                else
                    echo "Invalid selection. Press Enter to continue..."
                    read
                fi
                ;;
            n|N)
                if [[ $current_page -lt $total_pages ]]; then
                    ((current_page++))
                fi
                ;;
            p|P)
                if [[ $current_page -gt 1 ]]; then
                    ((current_page--))
                fi
                ;;
            f|F)
                current_page=1
                ;;
            l|L)
                current_page=$total_pages
                ;;
            q|Q)
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo "Invalid choice. Press Enter to continue..."
                read
                ;;
        esac
    done
}

# Run main function
main