#!/usr/bin/env bash

##############################################################
# vm_restore_menu.sh
# ----------------------------------------------------------
# Interactive menu for restoring VMs from OVA backup files.
# Lists vm-export-* restore points and allows selection of
# VMs to upload and restore back to Nutanix Prism Central.
# 
# Workflow:
# 1. Select restore point (vm-export-* folder)
# 2. Select VMs to restore from that backup
# 3. Upload OVAs to Prism Central
# 4. Restore VMs with original names and configurations
##############################################################

set -eu

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
MAX_UPLOAD_JOBS=4

# Find available restore points
find_restore_points() {
    local restore_points=()
    while IFS= read -r -d '' dir; do
        if [[ -f "$dir/vm_export_tasks.csv" ]]; then
            restore_points+=("$dir")
        fi
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name "vm-export-*" -print0 2>/dev/null)
    
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
    echo "         VM Restore Point Selection"
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
        
        # Convert timestamp to readable format
        # Input: 2025-07-09_03-11-33
        # Output: 9 Jul 2025, 3:11:33 AM
        local readable_timestamp=""
        if [[ $timestamp =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
            local year="${BASH_REMATCH[1]}"
            local month="${BASH_REMATCH[2]}"
            local day="${BASH_REMATCH[3]}"
            local hour="${BASH_REMATCH[4]}"
            local minute="${BASH_REMATCH[5]}"
            local second="${BASH_REMATCH[6]}"
            
            # Convert month number to name
            local month_names=("" "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
            local month_name="${month_names[$((10#$month))]}"
            
            # Convert 24-hour to 12-hour format
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
            
            # Remove leading zero from day
            local day_clean=$((10#$day))
            
            readable_timestamp="$day_clean $month_name $year, $hour_12:$minute:$second $ampm"
        else
            readable_timestamp="$timestamp"
        fi
        
        printf "%2d) %s (%d VMs)\n" "$((i+1))" "$readable_timestamp" "$vm_count"
    done
    
    echo ""
    echo "Actions:"
    echo "  [number] - Select restore point"
    echo "  q        - Quit"
    echo ""
}

# Load VM data from selected restore point
load_vm_data() {
    local restore_point="$1"
    local tasks_file="$restore_point/vm_export_tasks.csv"
    
    declare -g -a vm_data=()
    
    if [[ ! -f "$tasks_file" ]]; then
        echo "Error: Tasks file not found in $restore_point"
        return 1
    fi
    
    while IFS=',' read -r vm_name vm_uuid project_name task_uuid ova_name; do
        [[ "$vm_name" == "VM_NAME" ]] && continue
        
        # Check if OVA file exists
        local ova_file="$restore_point/${ova_name}.ova"
        if [[ -f "$ova_file" ]]; then
            vm_data+=("$project_name|$vm_name|$vm_uuid|$ova_name|$ova_file")
        fi
    done < "$tasks_file"
    
    if [[ ${#vm_data[@]} -eq 0 ]]; then
        echo "No valid VM backup files found in $restore_point"
        return 1
    fi
}

# Display VM selection menu
display_vm_menu() {
    clear
    echo "==========================================="
    echo "         VM Restore Selection Menu"
    echo "==========================================="
    echo ""
    echo "Restore Point: $(basename "$CURRENT_RESTORE_POINT")"
    echo ""
    
    # Calculate pagination
    local total_items=${#vm_data[@]}
    local start_idx=$(( (current_page - 1) * items_per_page ))
    local end_idx=$(( start_idx + items_per_page - 1 ))
    if [[ $end_idx -ge $total_items ]]; then
        end_idx=$(( total_items - 1 ))
    fi
    
    echo "Available VMs for restore (sorted by project, then name):"
    echo "Page $current_page of $total_pages | Showing $(( start_idx + 1 ))-$(( end_idx + 1 )) of $total_items VMs"
    echo ""
    
    local current_project=""
    local index=1
    
    for vm in "${vm_data[@]}"; do
        IFS='|' read -r project name uuid ova_name ova_file <<< "$vm"
        
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
            
            local status=""
            if [[ -n "${selected[$index]:-}" ]]; then
                status="[SELECTED]"
            fi
            
            # Show file size
            local file_size=$(stat -c%s "$ova_file" 2>/dev/null || echo "0")
            local size_mb=$(( file_size / 1024 / 1024 ))
            
            printf "%3d) %-25s (%dMB) %s\n" "$index" "$name" "$size_mb" "$status"
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
    echo "Selection:"
    echo "  [number]  - Toggle selection"
    echo "  a         - Select all VMs"
    echo "  c         - Clear all selections"
    echo "  proj      - Select all VMs in a project"
    echo ""
    echo "Actions:"
    echo "  r         - Restore selected VMs"
    echo "  s         - Show selection summary"
    echo "  b         - Back to restore point selection"
    echo "  q         - Quit"
    echo ""
    echo "Selected: ${#selected[@]} VMs"
    echo ""
}

# Show selection summary
show_selection_summary() {
    clear
    echo "==========================================="
    echo "        Restore Selection Summary"
    echo "==========================================="
    echo ""
    
    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "No VMs selected for restore."
        echo ""
        read -p "Press Enter to continue..."
        return
    fi
    
    echo "Selected VMs for restore (${#selected[@]} total):"
    echo ""
    
    local current_project=""
    local total_size=0
    
    for idx in $(printf '%s\n' "${!selected[@]}" | sort -n); do
        vm="${vm_data[$((idx-1))]}"
        IFS='|' read -r project name uuid ova_name ova_file <<< "$vm"
        
        if [[ "$project" != "$current_project" ]]; then
            if [[ -n "$current_project" ]]; then
                echo ""
            fi
            echo "Project: $project"
            echo "----------------------------------------"
            current_project="$project"
        fi
        
        local file_size=$(stat -c%s "$ova_file" 2>/dev/null || echo "0")
        local size_mb=$(( file_size / 1024 / 1024 ))
        total_size=$(( total_size + size_mb ))
        
        printf "  %3d) %-25s (%dMB)\n" "$idx" "$name" "$size_mb"
    done
    
    echo ""
    echo "Total size to upload: ${total_size}MB"
    echo ""
    read -p "Press Enter to continue..."
}

# Select VMs by project
select_project_vms() {
    clear
    echo "==========================================="
    echo "        Select VMs by Project"
    echo "==========================================="
    echo ""
    
    # Get unique projects
    declare -A seen_projects
    local unique_projects=()
    
    for vm_line in "${vm_data[@]}"; do
        IFS='|' read -r proj name uuid ova_name ova_file <<< "$vm_line"
        if [[ -n "$proj" && -z "${seen_projects[$proj]:-}" ]]; then
            seen_projects["$proj"]=1
            unique_projects+=("$proj")
        fi
    done
    
    if [[ ${#unique_projects[@]} -eq 0 ]]; then
        echo "Error: No projects found in VM data."
        echo ""
        read -p "Press Enter to continue..."
        return
    fi
    
    echo "Available projects:"
    echo ""
    
    for i in "${!unique_projects[@]}"; do
        local project="${unique_projects[i]}"
        local vm_count=0
        for vm_line in "${vm_data[@]}"; do
            IFS='|' read -r vm_proj vm_name vm_uuid vm_ova vm_file <<< "$vm_line"
            if [[ "$vm_proj" == "$project" ]]; then
                vm_count=$((vm_count + 1))
            fi
        done
        printf "%2d) %-20s (%d VMs)\n" "$((i+1))" "$project" "$vm_count"
    done
    
    echo ""
    read -p "Select project number (or 'b' to go back): " proj_choice
    
    if [[ "$proj_choice" =~ ^[0-9]+$ ]] && [[ "$proj_choice" -ge 1 && "$proj_choice" -le ${#unique_projects[@]} ]]; then
        local selected_project="${unique_projects[$((proj_choice-1))]}"
        local count=0
        
        for i in "${!vm_data[@]}"; do
            vm="${vm_data[i]}"
            IFS='|' read -r project name uuid ova_name ova_file <<< "$vm"
            if [[ "$project" == "$selected_project" ]]; then
                selected[$((i+1))]=1
                count=$((count + 1))
            fi
        done
        
        echo ""
        echo "Selected $count VMs from project '$selected_project'"
        sleep 1
    elif [[ "$proj_choice" != "b" && "$proj_choice" != "B" ]]; then
        echo "Invalid selection."
        sleep 1
    fi
}

# Upload OVA file to Prism Central
upload_ova() {
    local ova_file="$1"
    local ova_name="$2"
    local vm_name="$3"
    
    # echo "DEBUG: Starting upload_ova for $vm_name" >&2
    
    local filesize=$(stat -c%s "$ova_file")
    
    # Update status: Generating checksum
    update_restore_status "$vm_name" "GENERATING_SHA1" 0
    
    local full_cs=$(sha1sum "$ova_file" | cut -d' ' -f1)
    
    # Update status: Creating entity
    update_restore_status "$vm_name" "CREATING_ENTITY" 0
    
    # Create OVA entity
    local create_resp=$(curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM/api/nutanix/v3/ovas" \
        -H 'Content-Type: application/json' \
        -d '{"name":"'"$ova_name"'","upload_length":'"$filesize"',"checksum":{"checksum_algorithm":"SHA_1","checksum_value":"'"$full_cs"'"}}')
    
    local task_uuid=$(jq -r '.task_uuid // empty' <<< "$create_resp")
    if [[ -z "$task_uuid" ]]; then
        echo "DEBUG: Failed to get task_uuid from create response:"
        echo "DEBUG: Response: $create_resp"
        update_restore_status "$vm_name" "FAILED" 0
        return 1
    fi
    
    # Wait for OVA UUID
    local ova_uuid=""
    while [[ -z "$ova_uuid" ]]; do
        local task_json=$(curl -s -k -u "$USER:$PASS" \
            -X GET "https://$PRISM/api/nutanix/v3/tasks/$task_uuid" \
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
    
    # Build list of offsets and upload sequentially for proper progress tracking
    local offsets=()
    for (( off=0; off<filesize; off+=CHUNK_SIZE )); do
        offsets+=( "$off" )
    done
    
    # Upload chunks sequentially to maintain proper progress display
    for off in "${offsets[@]}"; do
        local bytes=$(( filesize - off < CHUNK_SIZE ? filesize - off : CHUNK_SIZE ))
        local tmpf cs
        
        tmpf=$(mktemp)
        dd if="$ova_file" of="$tmpf" bs=$CHUNK_SIZE skip=$((off/CHUNK_SIZE)) count=1 status=none 2>/dev/null
        
        cs=$(sha1sum "$tmpf" | cut -d' ' -f1)
        
        curl -s -k -u "$USER:$PASS" \
            -X PUT "https://$PRISM/api/nutanix/v3/ovas/$ova_uuid/chunks" \
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
        -X POST "https://$PRISM/api/nutanix/v3/ovas/$ova_uuid/chunks/concatenate" \
        -H 'Accept: application/json')
    
    local concat_task=$(jq -r '.task_uuid // empty' <<< "$concat_resp")
    
    if [[ -z "$concat_task" ]]; then
        echo "DEBUG: Failed to get concatenation task_uuid:"
        echo "DEBUG: Response: $concat_resp"
        update_restore_status "$vm_name" "FAILED" 0
        return 1
    fi
    
    # Monitor concatenation
    local max_wait_time=600  # 10 minutes max
    local elapsed_time=0
    
    while :; do
        local task_json=$(curl -s -k -u "$USER:$PASS" \
            -X GET "https://$PRISM/api/nutanix/v3/tasks/$concat_task" \
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
    
    echo "$ova_uuid"  # Return OVA UUID for restore
}

# Build resource maps (subnets, clusters, projects, OVAs)
build_resource_maps() {
    # Declare global associative arrays first
    declare -gA SUBNET_MAP=()
    declare -gA CLUSTER_MAP=()
    declare -gA PROJECT_MAP=()
    declare -gA OVA_MAP=()
    
    # Build associative map for API resources
    build_map() {
        local endpoint="$1" kind="$2" name_key="$3" uuid_key="$4" map_name="$5" search_range="$6"
        local json
        
        json=$(curl -s -k -u "$USER:$PASS" \
            -X POST "https://$PRISM/api/nutanix/v3/$endpoint/list" \
            -H 'Content-Type: application/json' \
            -d '{
                "kind": "'"$kind"'",
                "length": '"$search_range"',
                "offset": 0,
                "sort_attribute": "name",
                "sort_order": "ASCENDING"
            }')
        
        # Check if API call was successful
        if [[ -z "$json" ]] || ! jq -e '.entities' <<< "$json" >/dev/null 2>&1; then
            echo "Warning: Failed to fetch $endpoint or empty response"
            return 1
        fi
        
        # Parse and populate map without eval
        local temp_file=$(mktemp)
        jq -r ".entities[]? | select(.$name_key != null and .$uuid_key != null) | .$name_key + \"=\" + .$uuid_key" <<< "$json" > "$temp_file"
        
        while IFS='=' read -r name uuid; do
            [[ -n "$name" && -n "$uuid" ]] || continue
            case "$map_name" in
                SUBNET_MAP)  SUBNET_MAP["$name"]="$uuid" ;;
                CLUSTER_MAP) CLUSTER_MAP["$name"]="$uuid" ;;
                PROJECT_MAP) PROJECT_MAP["$name"]="$uuid" ;;
                OVA_MAP)     OVA_MAP["$name"]="$uuid" ;;
            esac
        done < "$temp_file"
        
        rm -f "$temp_file"
    }
    
    build_map "subnets"  "subnet"  "status.name"      "metadata.uuid" SUBNET_MAP 1000
    build_map "clusters" "cluster" "spec.name"        "metadata.uuid" CLUSTER_MAP 1000
    build_map "projects" "project" "status.name"      "metadata.uuid" PROJECT_MAP 100
    # Skip OVA fetching since we're uploading new ones
}

# Restore VM from uploaded OVA
restore_vm() {
    local vm_name="$1"
    local vm_uuid="$2"
    local project_name="$3"
    local ova_uuid="$4"
    
    # echo "DEBUG: Starting restore_vm function for $vm_name" >&2
    
    update_restore_status "$vm_name" "RESTORING" 0
    
    # Fetch VM spec from OVA
    local vm_spec_json=$(curl -s -k -u "$USER:$PASS" \
        -X GET "https://$PRISM/api/nutanix/v3/ovas/$ova_uuid/vm_spec" \
        -H 'Content-Type: application/json')
    
    if [[ -z "$vm_spec_json" ]] || ! jq -e '.vm_spec.spec' <<< "$vm_spec_json" >/dev/null 2>&1; then
        echo "DEBUG: Failed to fetch VM spec from OVA $ova_uuid"
        echo "DEBUG: Response: $vm_spec_json"
        update_restore_status "$vm_name" "FAILED" 0
        return 1
    fi
    
    local spec=$(jq '.vm_spec.spec' <<< "$vm_spec_json")
    
    # Update NIC subnet UUIDs using SUBNET_MAP
    local updated_nics=()
    while read -r nic; do
        local name=$(jq -r '.subnet_reference.name // empty' <<< "$nic")
        if [[ -n "$name" && -n "${SUBNET_MAP[$name]:-}" ]]; then
            local new_uuid=${SUBNET_MAP[$name]}
            nic=$(jq --arg uuid "$new_uuid" '.subnet_reference.uuid = $uuid' <<< "$nic")
        fi
        updated_nics+=("$nic")
    done < <(jq -c '.resources.nic_list[]?' <<< "$spec")
    
    if [[ ${#updated_nics[@]} -gt 0 ]]; then
        local nic_array=$(printf '%s\n' "${updated_nics[@]}" | jq -s '.')
        spec=$(jq --argjson nics "$nic_array" '.resources.nic_list = $nics' <<< "$spec")
    fi
    
    # Check project mapping
    local proj_uuid="${PROJECT_MAP[$project_name]:-}"
    if [[ -z "$proj_uuid" ]]; then
        echo "DEBUG: Project '$project_name' not found in PROJECT_MAP"
        echo "DEBUG: Available projects: ${!PROJECT_MAP[@]}"
        update_restore_status "$vm_name" "FAILED" 0
        return 1
    fi
    
    # Assemble VM creation payload with original VM name and project
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
            spec: $spec
        }')
    
    # Submit VM creation
    local create_resp=$(curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM/api/nutanix/v3/vms" \
        -H 'Content-Type: application/json' \
        -d "$payload")
    
    local new_vm_uuid=$(jq -r '.metadata.uuid // empty' <<< "$create_resp")
    local task_id=$(jq -r '.status.execution_context.task_uuid // empty' <<< "$create_resp")
    
    if [[ -z "$new_vm_uuid" || -z "$task_id" ]]; then
        echo "DEBUG: Failed to create VM $vm_name"
        echo "DEBUG: Payload: $payload"
        echo "DEBUG: Response: $create_resp"
        update_restore_status "$vm_name" "FAILED" 0
        return 1
    fi
    
    # Log restore task
    echo "$vm_name,$project_name,$ova_uuid,$new_vm_uuid,$task_id" >> "$RESTORE_LOG"
    
    # Monitor restore progress
    while :; do
        local task_json=$(curl -s -k -u "$USER:$PASS" \
            -X GET "https://$PRISM/api/nutanix/v3/tasks/$task_id" \
            -H 'Accept: application/json')
        local status_now=$(jq -r '.status' <<< "$task_json")
        local pc=$(jq -r '.percentage_complete // 0' <<< "$task_json")
        
        update_restore_status "$vm_name" "RESTORING" "$pc"
        
        if [[ "$status_now" == "SUCCEEDED" ]]; then
            update_restore_status "$vm_name" "COMPLETED" 100
            break
        elif [[ "$status_now" == "FAILED" ]]; then
            echo "DEBUG: VM restore task failed for $vm_name"
            echo "DEBUG: Task response: $task_json"
            update_restore_status "$vm_name" "FAILED" 0
            break
        fi
        sleep $POLL_INTERVAL
    done
}

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
    
    # echo "DEBUG: Updating $vm_name to $status ($progress%)" >&2
    
    RESTORE_STATUS["$vm_name"]="$status"
    RESTORE_PROGRESS["$vm_name"]="$progress"
    
    # Always refresh display immediately with a small delay
    print_restore_table >&2
    sleep 0.1
}

# Start background refresh for monitoring (simplified)
start_progress_monitor() {
    MONITORING_MODE=1
    # Just display initial table
    print_restore_table >&2
}

# Stop background refresh
stop_progress_monitor() {
    unset MONITORING_MODE
    # Show final table
    print_restore_table >&2
}

# Function to delete uploaded OVAs from Prism Central
delete_uploaded_ovas() {
    echo ""
    echo "🗑️  Deleting uploaded OVAs from Prism Central..."
    echo ""
    
    # Get list of uploaded OVAs from restore log
    if [[ ! -f "$RESTORE_LOG" ]]; then
        echo "No restore log found. Cannot determine which OVAs to delete."
        return 1
    fi
    
    # Read OVA UUIDs from restore log
    declare -A ova_uuids_to_delete=()
    declare -A vm_name_map=()
    declare -A vm_project_map=()
    while IFS=',' read -r vm_name project_name ova_uuid new_vm_uuid task_uuid; do
        [[ "$vm_name" == "VM_NAME" ]] && continue
        [[ -z "$ova_uuid" ]] && continue
        
        ova_uuids_to_delete["$ova_uuid"]=1
        vm_name_map["$ova_uuid"]="$vm_name"
        vm_project_map["$ova_uuid"]="$project_name"
    done < "$RESTORE_LOG"
    
    if [[ ${#ova_uuids_to_delete[@]} -eq 0 ]]; then
        echo "No OVAs found to delete."
        return 1
    fi
    
    # Calculate column widths for table display
    local max_name_width=7
    local max_project_width=7
    for ova_uuid in "${!ova_uuids_to_delete[@]}"; do
        vm_name="${vm_name_map[$ova_uuid]}"
        vm_project="${vm_project_map[$ova_uuid]}"
        if [[ ${#vm_name} -gt $max_name_width ]]; then
            max_name_width=${#vm_name}
        fi
        if [[ ${#vm_project} -gt $max_project_width ]]; then
            max_project_width=${#vm_project}
        fi
    done
    max_name_width=$((max_name_width + 2))
    max_project_width=$((max_project_width + 2))
    
    # Display header
    printf "%-${max_name_width}s %-${max_project_width}s %-10s %-10s\n" "VM_NAME" "PROJECT" "UUID" "STATUS"
    printf -- "$(printf '%*s' $((max_name_width + max_project_width + 25)) '-' | tr ' ' '-')\n"
    
    # Delete each OVA with status display
    declare -A deletion_status=()
    for ova_uuid in "${!ova_uuids_to_delete[@]}"; do
        vm_name="${vm_name_map[$ova_uuid]}"
        vm_project="${vm_project_map[$ova_uuid]}"
        
        printf "%-${max_name_width}s %-${max_project_width}s %-10s " "$vm_name" "$vm_project" "${ova_uuid:0:8}..."
        
        # Perform deletion
        resp=$(curl -s -k -u "$USER:$PASS" \
            -X DELETE "https://$PRISM/api/nutanix/v3/ovas/$ova_uuid" \
            -H 'Content-Type: application/json')
        
        # Check if deletion was successful
        if [[ $? -eq 0 ]]; then
            printf "✅ DELETED\n"
            deletion_status["$ova_uuid"]="success"
        else
            printf "✗ FAILED\n"
            deletion_status["$ova_uuid"]="failed"
        fi
    done
    
    # Summary
    echo ""
    local success_count=0
    local failed_count=0
    
    for status in "${deletion_status[@]}"; do
        case "$status" in
            "success") success_count=$((success_count + 1)) ;;
            "failed") failed_count=$((failed_count + 1)) ;;
        esac
    done
    
    echo "Deletion Summary:"
    echo "✅ Successfully deleted: $success_count"
    if [[ $failed_count -gt 0 ]]; then
        echo "✗ Failed to delete: $failed_count"
    fi
    echo ""
    echo "🗑️  OVA cleanup completed."
}

# Main restore workflow
perform_restore() {
    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "No VMs selected for restore."
        read -p "Press Enter to continue..."
        return
    fi
    
    echo ""
    echo "Starting restore process for ${#selected[@]} VMs..."
    echo ""
    
    # Prepare restore log
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    RESTORE_LOG="$SCRIPT_DIR/restore_tasks_$timestamp.csv"
    echo "VM_NAME,PROJECT_NAME,OVA_UUID,NEW_VM_UUID,TASK_UUID" > "$RESTORE_LOG"
    
    # Initialize internal arrays
    declare -g -A RESTORE_VM_DATA=()
    declare -g -A RESTORE_STATUS=()
    declare -g -A RESTORE_PROGRESS=()
    
    # Populate internal arrays with selected VMs
    for idx in "${!selected[@]}"; do
        vm="${vm_data[$((idx-1))]}"
        IFS='|' read -r project name uuid ova_name ova_file <<< "$vm"
        
        RESTORE_VM_DATA["$name"]="$project|$ova_name"
        RESTORE_STATUS["$name"]="PENDING"
        RESTORE_PROGRESS["$name"]="0"
    done
    
    # Display initial table
    print_restore_table
    
    # Build resource maps silently
    build_resource_maps
    
    # Start progress monitor
    start_progress_monitor
    
    # Process each selected VM one at a time
    for idx in "${!selected[@]}"; do
        vm="${vm_data[$((idx-1))]}"
        IFS='|' read -r project name uuid ova_name ova_file <<< "$vm"
        
        # Upload OVA
        # echo "DEBUG: About to call upload_ova for $name" >&2
        local ova_uuid
        if ova_uuid=$(upload_ova "$ova_file" "$ova_name" "$name"); then
            # echo "DEBUG: upload_ova succeeded, returned: '$ova_uuid'" >&2
            if [[ -n "$ova_uuid" ]]; then
                # echo "DEBUG: Starting restore_vm for $name with OVA UUID: $ova_uuid" >&2
                # Restore VM
                if restore_vm "$name" "$uuid" "$project" "$ova_uuid"; then
                    # echo "DEBUG: restore_vm succeeded for $name" >&2
                    :
                else
                    # echo "DEBUG: restore_vm failed for $name" >&2
                    :
                fi
            else
                # echo "DEBUG: upload_ova returned empty UUID for $name" >&2
                update_restore_status "$name" "FAILED" 0
            fi
        else
            # echo "DEBUG: upload_ova function failed for $name" >&2
            echo "Upload failed for $name, skipping restore"
        fi
    done
    
    # Stop background monitor and show final status
    stop_progress_monitor
    
    echo ""
    echo "✅ Restore process completed!"
    echo "Log file: $RESTORE_LOG"
    
    # Ask if user wants to delete uploaded OVAs from Prism Central
    echo ""
    read -p "Do you want to delete the uploaded OVAs from Prism Central? (y/N): " delete_choice
    if [[ "$delete_choice" =~ ^[Yy] ]]; then
        delete_uploaded_ovas
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Main execution
main() {
    while true; do
        display_restore_points
        read -p "Enter choice: " choice
        
        case "$choice" in
            [0-9]*)
                local restore_points
                mapfile -t restore_points < <(find_restore_points)
                
                if [[ "$choice" -ge 1 && "$choice" -le ${#restore_points[@]} ]]; then
                    CURRENT_RESTORE_POINT="${restore_points[$((choice-1))]}"
                    
                    if load_vm_data "$CURRENT_RESTORE_POINT"; then
                        # Initialize VM selection variables
                        declare -A selected=()
                        items_per_page=15
                        current_page=1
                        total_pages=$(( (${#vm_data[@]} + items_per_page - 1) / items_per_page ))
                        
                        # VM selection menu loop
                        while true; do
                            display_vm_menu
                            read -p "Enter choice: " vm_choice
                            
                            case "$vm_choice" in
                                [0-9]*)
                                    if [[ "$vm_choice" -ge 1 && "$vm_choice" -le ${#vm_data[@]} ]]; then
                                        if [[ -n "${selected[$vm_choice]:-}" ]]; then
                                            unset selected[$vm_choice]
                                        else
                                            selected[$vm_choice]=1
                                        fi
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
                                a|A)
                                    for ((i=1; i<=${#vm_data[@]}; i++)); do
                                        selected[$i]=1
                                    done
                                    ;;
                                c|C)
                                    selected=()
                                    ;;
                                proj|PROJ)
                                    select_project_vms
                                    ;;
                                s|S)
                                    show_selection_summary
                                    ;;
                                r|R)
                                    perform_restore
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
                    fi
                else
                    echo "Invalid selection. Press Enter to continue..."
                    read
                fi
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