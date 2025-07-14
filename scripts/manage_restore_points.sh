#!/usr/bin/env bash

##############################################################
# manage_restore_points.sh
# ----------------------------------------------------------
# Interactive menu for managing VM backup restore points.
# Allows users to view, delete, and get statistics about
# available restore points in the restore-points folder.
# 
# Features:
# - View all restore points with details
# - Delete individual restore points
# - Delete multiple restore points
# - Show storage usage statistics
# - Safe deletion with confirmation prompts
##############################################################

set -eu

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_POINTS_DIR="$SCRIPT_DIR/restore-points"

# Colors for output - improved for better readability
RED='\033[0;31m'        # Red for errors
GREEN='\033[0;32m'      # Green for success
YELLOW='\033[1;33m'     # Bright yellow for warnings
CYAN='\033[0;36m'       # Cyan for info (replaces dark blue)
MAGENTA='\033[0;35m'    # Magenta for headers
BOLD='\033[1m'          # Bold text
DIM='\033[2m'           # Dim text for less important info
NC='\033[0m'            # No Color

# Check if restore-points directory exists
if [[ ! -d "$RESTORE_POINTS_DIR" ]]; then
    echo "No restore-points directory found. Creating it..."
    mkdir -p "$RESTORE_POINTS_DIR"
fi

# Find available restore points
find_restore_points() {
    local restore_points=()
    while IFS= read -r -d '' dir; do
        if [[ -f "$dir/vm_export_tasks.csv" ]]; then
            restore_points+=("$dir")
        fi
    done < <(find "$RESTORE_POINTS_DIR" -maxdepth 1 -type d -name "vm-export-*" -print0 2>/dev/null)
    
    printf '%s\n' "${restore_points[@]}" | sort -r  # Most recent first
}

# Convert bytes to human readable format
human_readable_size() {
    local bytes=$1
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    
    while [[ $bytes -gt 1024 && $unit -lt 4 ]]; do
        bytes=$((bytes / 1024))
        ((unit++))
    done
    
    echo "${bytes}${units[$unit]}"
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
    
    echo "$readable_timestamp|$vm_count|$total_size"
}

# Display main menu
display_main_menu() {
    clear
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
    echo -e "        Restore Points Management"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
    echo ""
    
    local restore_points
    mapfile -t restore_points < <(find_restore_points)
    
    if [[ ${#restore_points[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No restore points found.${NC}"
        echo ""
        echo "Run vm_export_menu.sh to create backup restore points."
        echo ""
        echo "Actions:"
        echo "  q - Quit"
        echo ""
        return
    fi
    
    echo "Available restore points:"
    echo ""
    
    # Calculate total storage used
    local total_storage=0
    local total_vms=0
    
    printf "%-3s %-35s %-5s %-10s\n" "ID" "BACKUP_DATE" "VMs" "SIZE"
    echo "------------------------------------------------------------"
    
    for i in "${!restore_points[@]}"; do
        local restore_point="${restore_points[i]}"
        local details
        details=$(get_restore_point_details "$restore_point")
        IFS='|' read -r readable_date vm_count size_bytes <<< "$details"
        
        local size_display=$(human_readable_size "$size_bytes")
        
        printf "%-3d %-35s %-5d %-10s\n" "$((i+1))" "$readable_date" "$vm_count" "$size_display"
        
        total_storage=$((total_storage + size_bytes))
        total_vms=$((total_vms + vm_count))
    done
    
    echo "------------------------------------------------------------"
    local total_display=$(human_readable_size "$total_storage")
    printf "%-3s %-35s %-5d %-10s\n" "" "TOTAL" "$total_vms" "$total_display"
    
    echo ""
    echo "Actions:"
    echo "  [number] - View restore point details"
    echo "  d        - Delete restore point(s)"
    echo "  s        - Storage statistics"
    echo "  q        - Quit"
    echo ""
}

# Display restore point details
display_restore_point_details() {
    local restore_point="$1"
    local index="$2"
    
    clear
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
    echo -e "        Restore Point Details"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
    echo ""
    
    local details
    details=$(get_restore_point_details "$restore_point")
    IFS='|' read -r readable_date vm_count size_bytes <<< "$details"
    
    local size_display=$(human_readable_size "$size_bytes")
    local tasks_file="$restore_point/vm_export_tasks.csv"
    
    echo "Restore Point #$index"
    echo "Date: $readable_date"
    echo "VMs: $vm_count"
    echo "Size: $size_display"
    echo "Path: $restore_point"
    echo ""
    
    if [[ -f "$tasks_file" && $vm_count -gt 0 ]]; then
        echo "VM Details:"
        echo "----------------------------------------"
        printf "%-25s %-20s %-10s\n" "VM_NAME" "PROJECT" "STATUS"
        echo "----------------------------------------"
        
        while IFS=',' read -r vm_name vm_uuid project_name task_uuid ova_name; do
            [[ "$vm_name" == "VM_NAME" ]] && continue
            
            local ova_file="$restore_point/${ova_name}.ova"
            local status="Missing"
            if [[ -f "$ova_file" ]]; then
                status="Available"
            fi
            
            printf "%-25s %-20s %-10s\n" "$vm_name" "$project_name" "$status"
        done < "$tasks_file"
        
        echo ""
    fi
    
    echo "Actions:"
    echo "  d - Delete this restore point"
    echo "  b - Back to main menu"
    echo "  q - Quit"
    echo ""
}

# Delete restore point with confirmation
delete_restore_point() {
    local restore_point="$1"
    local index="$2"
    
    local details
    details=$(get_restore_point_details "$restore_point")
    IFS='|' read -r readable_date vm_count size_bytes <<< "$details"
    
    local size_display=$(human_readable_size "$size_bytes")
    
    echo -e "${YELLOW}WARNING: You are about to delete restore point #$index${NC}"
    echo "Date: $readable_date"
    echo "VMs: $vm_count"
    echo "Size: $size_display"
    echo ""
    echo -e "${RED}This action cannot be undone!${NC}"
    echo ""
    
    read -p "Type 'DELETE' to confirm deletion: " confirm
    
    if [[ "$confirm" == "DELETE" ]]; then
        echo ""
        echo "Deleting restore point..."
        
        if rm -rf "$restore_point"; then
            echo -e "${GREEN}✅ Restore point deleted successfully${NC}"
        else
            echo -e "${RED}✗ Failed to delete restore point${NC}"
        fi
    else
        echo "Deletion cancelled."
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Delete multiple restore points
delete_multiple_restore_points() {
    local restore_points
    mapfile -t restore_points < <(find_restore_points)
    
    if [[ ${#restore_points[@]} -eq 0 ]]; then
        echo "No restore points available to delete."
        read -p "Press Enter to continue..."
        return
    fi
    
    clear
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
    echo -e "        Delete Multiple Restore Points"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
    echo ""
    
    declare -A selected=()
    
    while true; do
        clear
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
        echo -e "        Delete Multiple Restore Points"
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
        echo ""
        
        echo "Select restore points to delete:"
        echo ""
        
        printf "%-3s %-35s %-5s %-10s %-10s\n" "ID" "BACKUP_DATE" "VMs" "SIZE" "SELECTED"
        echo "--------------------------------------------------------------------"
        
        for i in "${!restore_points[@]}"; do
            local restore_point="${restore_points[i]}"
            local details
            details=$(get_restore_point_details "$restore_point")
            IFS='|' read -r readable_date vm_count size_bytes <<< "$details"
            
            local size_display=$(human_readable_size "$size_bytes")
            local status=""
            if [[ -n "${selected[$((i+1))]:-}" ]]; then
                status="[X]"
            fi
            
            printf "%-3d %-35s %-5d %-10s %-10s\n" "$((i+1))" "$readable_date" "$vm_count" "$size_display" "$status"
        done
        
        echo ""
        echo "Actions:"
        echo "  [number] - Toggle selection"
        echo "  a        - Select all"
        echo "  c        - Clear selections"
        echo "  delete   - Delete selected restore points"
        echo "  b        - Back to main menu"
        echo ""
        echo "Selected: ${#selected[@]} restore points"
        echo ""
        
        read -p "Enter choice: " choice
        
        case "$choice" in
            [0-9]*)
                if [[ "$choice" -ge 1 && "$choice" -le ${#restore_points[@]} ]]; then
                    if [[ -n "${selected[$choice]:-}" ]]; then
                        unset selected[$choice]
                    else
                        selected[$choice]=1
                    fi
                else
                    echo "Invalid selection."
                    sleep 1
                fi
                ;;
            a|A)
                for ((i=1; i<=${#restore_points[@]}; i++)); do
                    selected[$i]=1
                done
                ;;
            c|C)
                selected=()
                ;;
            delete|DELETE)
                if [[ ${#selected[@]} -eq 0 ]]; then
                    echo "No restore points selected."
                    sleep 1
                    continue
                fi
                
                # Show confirmation
                echo ""
                echo -e "${YELLOW}WARNING: You are about to delete ${#selected[@]} restore point(s)${NC}"
                echo ""
                echo "Selected restore points:"
                for idx in "${!selected[@]}"; do
                    local restore_point="${restore_points[$((idx-1))]}"
                    local details
                    details=$(get_restore_point_details "$restore_point")
                    IFS='|' read -r readable_date vm_count size_bytes <<< "$details"
                    echo "  $idx) $readable_date ($vm_count VMs)"
                done
                echo ""
                echo -e "${RED}This action cannot be undone!${NC}"
                echo ""
                
                read -p "Type 'DELETE' to confirm deletion: " confirm
                
                if [[ "$confirm" == "DELETE" ]]; then
                    echo ""
                    echo "Deleting selected restore points..."
                    
                    local success_count=0
                    local fail_count=0
                    
                    for idx in "${!selected[@]}"; do
                        local restore_point="${restore_points[$((idx-1))]}"
                        local details
                        details=$(get_restore_point_details "$restore_point")
                        IFS='|' read -r readable_date vm_count size_bytes <<< "$details"
                        
                        echo -n "→ Deleting $readable_date... "
                        
                        if rm -rf "$restore_point"; then
                            echo -e "${GREEN}✅ Success${NC}"
                            success_count=$((success_count + 1))
                        else
                            echo -e "${RED}✗ Failed${NC}"
                            fail_count=$((fail_count + 1))
                        fi
                    done
                    
                    echo ""
                    echo "Deletion Summary:"
                    echo "✅ Successfully deleted: $success_count"
                    if [[ $fail_count -gt 0 ]]; then
                        echo "✗ Failed to delete: $fail_count"
                    fi
                else
                    echo "Deletion cancelled."
                fi
                
                echo ""
                read -p "Press Enter to continue..."
                return
                ;;
            b|B)
                return
                ;;
            *)
                echo "Invalid choice."
                sleep 1
                ;;
        esac
    done
}

# Show storage statistics
show_storage_statistics() {
    clear
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
    echo -e "        Storage Statistics"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════${NC}"
    echo ""
    
    local restore_points
    mapfile -t restore_points < <(find_restore_points)
    
    if [[ ${#restore_points[@]} -eq 0 ]]; then
        echo "No restore points found."
        echo ""
        read -p "Press Enter to continue..."
        return
    fi
    
    local total_storage=0
    local total_vms=0
    local total_files=0
    
    # Project breakdown
    declare -A project_stats
    declare -A project_vms
    
    for restore_point in "${restore_points[@]}"; do
        local details
        details=$(get_restore_point_details "$restore_point")
        IFS='|' read -r readable_date vm_count size_bytes <<< "$details"
        
        total_storage=$((total_storage + size_bytes))
        total_vms=$((total_vms + vm_count))
        
        # Count files
        local file_count=0
        if [[ -d "$restore_point" ]]; then
            file_count=$(find "$restore_point" -name "*.ova" -type f | wc -l)
        fi
        total_files=$((total_files + file_count))
        
        # Project breakdown
        local tasks_file="$restore_point/vm_export_tasks.csv"
        if [[ -f "$tasks_file" ]]; then
            while IFS=',' read -r vm_name vm_uuid project_name task_uuid ova_name; do
                [[ "$vm_name" == "VM_NAME" ]] && continue
                
                local ova_file="$restore_point/${ova_name}.ova"
                if [[ -f "$ova_file" ]]; then
                    local ova_size=$(stat -c%s "$ova_file" 2>/dev/null || echo "0")
                    project_stats["$project_name"]=$((${project_stats["$project_name"]:-0} + ova_size))
                    project_vms["$project_name"]=$((${project_vms["$project_name"]:-0} + 1))
                fi
            done < "$tasks_file"
        fi
    done
    
    echo "Overall Statistics:"
    echo "------------------------------------------------------------"
    echo "Total restore points: ${#restore_points[@]}"
    echo "Total VMs backed up: $total_vms"
    echo "Total OVA files: $total_files"
    echo "Total storage used: $(human_readable_size $total_storage)"
    echo ""
    
    if [[ ${#project_stats[@]} -gt 0 ]]; then
        echo "Storage by Project:"
        echo "------------------------------------------------------------"
        printf "%-30s %-5s %-10s\n" "PROJECT" "VMs" "SIZE"
        echo "------------------------------------------------------------"
        
        for project in "${!project_stats[@]}"; do
            local project_size="${project_stats[$project]}"
            local project_vm_count="${project_vms[$project]}"
            local size_display=$(human_readable_size "$project_size")
            
            printf "%-30s %-5d %-10s\n" "$project" "$project_vm_count" "$size_display"
        done
        
        echo ""
    fi
    
    # Disk usage of restore-points directory
    if command -v du >/dev/null 2>&1; then
        echo "Disk Usage:"
        echo "------------------------------------------------------------"
        local disk_usage=$(du -sh "$RESTORE_POINTS_DIR" 2>/dev/null | cut -f1)
        echo "Restore points directory: $disk_usage"
        echo ""
    fi
    
    read -p "Press Enter to continue..."
}

# Main menu loop
main() {
    while true; do
        display_main_menu
        
        local restore_points
        mapfile -t restore_points < <(find_restore_points)
        
        if [[ ${#restore_points[@]} -eq 0 ]]; then
            read -p "Enter choice: " choice
            case "$choice" in
                q|Q)
                    echo "Exiting..."
                    exit 0
                    ;;
                *)
                    echo "Invalid choice."
                    sleep 1
                    ;;
            esac
            continue
        fi
        
        read -p "Enter choice: " choice
        
        case "$choice" in
            [0-9]*)
                if [[ "$choice" -ge 1 && "$choice" -le ${#restore_points[@]} ]]; then
                    local selected_restore_point="${restore_points[$((choice-1))]}"
                    
                    while true; do
                        display_restore_point_details "$selected_restore_point" "$choice"
                        read -p "Enter choice: " detail_choice
                        
                        case "$detail_choice" in
                            d|D)
                                delete_restore_point "$selected_restore_point" "$choice"
                                break
                                ;;
                            b|B)
                                break
                                ;;
                            q|Q)
                                echo "Exiting..."
                                exit 0
                                ;;
                            *)
                                echo "Invalid choice."
                                sleep 1
                                ;;
                        esac
                    done
                else
                    echo "Invalid selection."
                    sleep 1
                fi
                ;;
            d|D)
                delete_multiple_restore_points
                ;;
            s|S)
                show_storage_statistics
                ;;
            q|Q)
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo "Invalid choice."
                sleep 1
                ;;
        esac
    done
}

# Run main function
main