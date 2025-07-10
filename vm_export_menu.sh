#!/usr/bin/env bash

##############################################################
# vm_export_menu.sh
# ----------------------------------------------------------
# Interactive menu for selecting and exporting VMs from Nutanix
# Prism Central. Lists VMs sorted by project then VM name.
# Allows multi-select for export and download.
##############################################################

set -eu

# Load credentials
source .nutanix_creds || { echo "Credentials file not found or unreadable"; exit 1; }

# Prerequisites
command -v jq   >/dev/null || { echo "Please install jq (apt install jq)"; exit 1; }
command -v curl >/dev/null || { echo "Please install curl (apt install curl)"; exit 1; }

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL=3

# Fetch VMs from Prism Central
echo "Fetching VMs from $PRISM..."
vms_json=$(curl -s -k -u "$USER:$PASS" \
  -X POST "https://$PRISM/api/nutanix/v3/vms/list" \
  -H 'Content-Type: application/json' \
  -d '{"length":1000}')

# Parse and filter VMs using pipe delimiter
declare -a vm_data=()
while IFS= read -r line; do
  vm_data+=("$line")
done < <(jq -r '.entities[] | select(.metadata.project_reference.name and .metadata.project_reference.name != "_internal") | "\(.metadata.project_reference.name)|\(.status.name)|\(.metadata.uuid)|\(.status.resources.power_state // "UNKNOWN")"' <<< "$vms_json" | sort)

if [[ ${#vm_data[@]} -eq 0 ]]; then
  echo "No qualifying VMs found. Exiting."
  exit 0
fi

# Display menu with pagination
display_menu() {
  clear
  echo "==========================================="
  echo "         VM Export Selection Menu"
  echo "==========================================="
  echo ""
  
  # Calculate pagination
  local total_items=${#vm_data[@]}
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
  local display_index=1
  
  for vm in "${vm_data[@]}"; do
    IFS='|' read -r project name uuid power_state <<< "$vm"
    
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
      
      # Format power state for display
      local power_display=""
      case "$power_state" in
        "ON") power_display="🟢 ON" ;;
        "OFF") power_display="🔴 OFF" ;;
        *) power_display="⚪ $power_state" ;;
      esac
      
      # Make sure we have a name to display
      if [[ -n "$name" ]]; then
        printf "%3d) %-30s %-10s %s\n" "$index" "$name" "$power_display" "$status"
      else
        printf "%3d) %-30s %-10s %s\n" "$index" "[NO NAME]" "$power_display" "$status"
      fi
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
  echo "  e         - Export selected VMs"
  echo "  s         - Show selection summary"
  echo "  q         - Quit"
  echo ""
  echo "Selected: ${#selected[@]} VMs"
  echo ""
}

# Initialize selection array and pagination
declare -A selected=()
items_per_page=15
current_page=1
total_pages=$(( (${#vm_data[@]} + items_per_page - 1) / items_per_page ))

# Function to show selection summary
show_selection_summary() {
  clear
  echo "==========================================="
  echo "        Selection Summary"
  echo "==========================================="
  echo ""
  
  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "No VMs selected."
    echo ""
    read -p "Press Enter to continue..."
    return
  fi
  
  echo "Selected VMs (${#selected[@]} total):"
  echo ""
  
  local current_project=""
  local count_by_project=()
  
  for idx in $(printf '%s\n' "${!selected[@]}" | sort -n); do
    vm="${vm_data[$((idx-1))]}"
    IFS='|' read -r project name uuid power_state <<< "$vm"
    
    if [[ "$project" != "$current_project" ]]; then
      if [[ -n "$current_project" ]]; then
        echo ""
      fi
      echo "Project: $project"
      echo "----------------------------------------"
      current_project="$project"
    fi
    
    # Format power state for display
    local power_display=""
    case "$power_state" in
      "ON") power_display="🟢 ON" ;;
      "OFF") power_display="🔴 OFF" ;;
      *) power_display="⚪ $power_state" ;;
    esac
    
    printf "  %3d) %-30s %s\n" "$idx" "$name" "$power_display"
  done
  
  echo ""
  read -p "Press Enter to continue..."
}

# Function to select all VMs in a project
select_project_vms() {
  clear
  echo "==========================================="
  echo "        Select VMs by Project"
  echo "==========================================="
  echo ""
  
  # Check vm_data array
  if [[ ${#vm_data[@]} -eq 0 ]]; then
    echo "Error: No VM data available."
    echo ""
    read -p "Press Enter to continue..."
    return
  fi
  
  # Get unique projects using pipe delimiter
  declare -A seen_projects
  local unique_projects=()
  
  for vm_line in "${vm_data[@]}"; do
    IFS='|' read -r proj name uuid power_state <<< "$vm_line"
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
      IFS='|' read -r vm_proj vm_name vm_uuid vm_power_state <<< "$vm_line"
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
      IFS='|' read -r project name uuid power_state <<< "$vm"
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

# Function to delete OVAs from Prism Central
delete_ovas_from_prism() {
  local ovas_json="$1"
  
  echo ""
  echo "🗑️  Deleting OVAs from Prism Central..."
  echo ""
  
  # Read the OVA names from the tasks file
  declare -A ova_names_to_delete vm_name_map vm_project_map
  while IFS=, read -r vm_name vm_uuid proj task_uuid ova_name; do
    [[ "$vm_name" == "VM_NAME" ]] && continue
    ova_names_to_delete["$ova_name"]=1
    vm_name_map["$ova_name"]="$vm_name"
    vm_project_map["$ova_name"]="$proj"
  done < "$TASKS_FILE"
  
  if [[ ${#ova_names_to_delete[@]} -eq 0 ]]; then
    echo "No OVAs found to delete."
    return
  fi
  
  # Map OVA names to UUIDs
  declare -A ova_uuid_map
  count=$(jq '.entities | length' <<< "$ovas_json")
  for (( i=0; i<count; i++ )); do
    name=$(jq -r ".entities[$i].info.name" <<< "$ovas_json")
    uuid=$(jq -r ".entities[$i].metadata.uuid" <<< "$ovas_json")
    ova_uuid_map["$name"]="$uuid"
  done
  
  # Calculate column widths for table display
  local max_name_width=7
  local max_project_width=7
  for ova in "${!ova_names_to_delete[@]}"; do
    vm_name="${vm_name_map[$ova]}"
    vm_project="${vm_project_map[$ova]}"
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
  declare -A deletion_status
  for ova in "${!ova_names_to_delete[@]}"; do
    vm_name="${vm_name_map[$ova]}"
    vm_project="${vm_project_map[$ova]}"
    
    if uuid="${ova_uuid_map[$ova]:-}"; then
      printf "%-${max_name_width}s %-${max_project_width}s %-10s " "$vm_name" "$vm_project" "${uuid:0:8}..."
      
      # Perform deletion
      resp=$(curl -s -k -u "$USER:$PASS" \
        -X DELETE "https://$PRISM/api/nutanix/v3/ovas/$uuid" \
        -H 'Content-Type: application/json')
      
      # Check if deletion was successful
      if [[ $? -eq 0 ]]; then
        printf "✅ DELETED\n"
        deletion_status["$ova"]="success"
      else
        printf "✗ FAILED\n"
        deletion_status["$ova"]="failed"
      fi
    else
      printf "%-${max_name_width}s %-${max_project_width}s %-10s ✗ NOT FOUND\n" "$vm_name" "$vm_project" "N/A"
      deletion_status["$ova"]="not_found"
    fi
  done
  
  # Summary
  echo ""
  local success_count=0
  local failed_count=0
  local not_found_count=0
  
  for status in "${deletion_status[@]}"; do
    case "$status" in
      "success") success_count=$((success_count + 1)) ;;
      "failed") failed_count=$((failed_count + 1)) ;;
      "not_found") not_found_count=$((not_found_count + 1)) ;;
    esac
  done
  
  echo "Deletion Summary:"
  echo "✅ Successfully deleted: $success_count"
  if [[ $failed_count -gt 0 ]]; then
    echo "✗ Failed to delete: $failed_count"
  fi
  if [[ $not_found_count -gt 0 ]]; then
    echo "⚠️  Not found: $not_found_count"
  fi
  echo ""
  echo "🗑️  OVA cleanup completed."
}

# Main menu loop
while true; do
  display_menu
  read -p "Enter choice: " choice
  
  case "$choice" in
    [0-9]*)
      if [[ "$choice" -ge 1 && "$choice" -le ${#vm_data[@]} ]]; then
        if [[ -n "${selected[$choice]:-}" ]]; then
          unset selected[$choice]
        else
          selected[$choice]=1
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
    e|E)
      if [[ ${#selected[@]} -eq 0 ]]; then
        echo "No VMs selected. Press Enter to continue..."
        read
        continue
      fi
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

# Export selected VMs
echo ""
echo "Exporting selected VMs..."
echo ""

# Create tasks file
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
DOWNLOAD_DIR="$SCRIPT_DIR/restore-points/vm-export-$TIMESTAMP"
mkdir -p "$DOWNLOAD_DIR"
TASKS_FILE="$DOWNLOAD_DIR/vm_export_tasks.csv"
echo "VM_NAME,VM_UUID,PROJECT_NAME,TASK_UUID,OVA_NAME" > "$TASKS_FILE"

declare -A task_map name_map project_map
declare -a selected_indices=($(printf '%s\n' "${!selected[@]}" | sort -n))

for idx in "${selected_indices[@]}"; do
  vm="${vm_data[$((idx-1))]}"
  IFS='|' read -r project name uuid power_state <<< "$vm"
  
  echo -n "→ $name ($project)... "
  
  resp=$(curl -s -k -u "$USER:$PASS" \
    -X POST "https://$PRISM/api/nutanix/v3/vms/$uuid/export" \
    -H 'Content-Type: application/json' \
    -d '{"disk_file_format":"QCOW2","name":"'$uuid'"}')
  
  task_uuid=$(jq -r '.task_uuid // empty' <<< "$resp")
  
  if [[ -n "$task_uuid" ]]; then
    echo "Task UUID=$task_uuid"
    task_map["$uuid"]=$task_uuid
    name_map["$uuid"]=$name
    project_map["$uuid"]=$project
    echo "$name,$uuid,$project,$task_uuid,$uuid" >> "$TASKS_FILE"
  else
    echo "✗ Failed to submit"
  fi
done

if [[ ${#task_map[@]} -eq 0 ]]; then
  echo "No exports were successfully submitted."
  exit 1
fi

# Monitor export progress
echo ""
echo "⏳ Monitoring export progress (Ctrl+C to stop)..."
echo ""

declare -A status_map pct_map

while true; do
  clear
  echo "Export Progress:"
  echo ""
  printf "%-30s %-15s %-10s %-10s\n" "VM_NAME" "PROJECT" "PROGRESS" "STATUS"
  echo "--------------------------------------------------------------------"
  
  for vm_uuid in "${!task_map[@]}"; do
    task_json=$(curl -s -k -u "$USER:$PASS" \
      -X GET "https://$PRISM/api/nutanix/v3/tasks/${task_map[$vm_uuid]}" \
      -H 'Accept: application/json')
    
    status=$(jq -r '.status' <<< "$task_json")
    pct=$(jq -r '.percentage_complete // 0' <<< "$task_json")
    
    status_map[$vm_uuid]="$status"
    pct_map[$vm_uuid]="$pct"
    
    printf "%-30s %-15s %3s%%       %s\n" \
      "${name_map[$vm_uuid]}" \
      "${project_map[$vm_uuid]}" \
      "$pct" \
      "$status"
  done
  
  # Check if all tasks succeeded
  all_succeeded=true
  for s in "${status_map[@]}"; do
    if [[ "$s" != "SUCCEEDED" ]]; then
      all_succeeded=false
      break
    fi
  done
  
  if $all_succeeded; then
    break
  fi
  
  sleep $POLL_INTERVAL
done

echo ""
echo "✅ All export tasks completed!"
echo ""

# Ask if user wants to download
read -p "Do you want to download the exported OVAs? (y/N): " download_choice
if [[ "$download_choice" =~ ^[Yy] ]]; then
  echo ""
  echo "Starting download process..."
  
  # Download directory already created during export
  
  # Fetch OVA list
  echo "Fetching OVA list..."
  ovas_json=$(curl -s -k -u "$USER:$PASS" \
    -X POST "https://$PRISM/api/nutanix/v3/ovas/list" \
    -H 'Content-Type: application/json' \
    -d '{"kind":"ova","length":1000,"offset":0,"sort_attribute":"name","sort_order":"ASCENDING"}')
  
  # Download each OVA
  for vm_uuid in "${!task_map[@]}"; do
    vm_name="${name_map[$vm_uuid]}"
    ova_name="$vm_uuid"
    
    echo -n "→ Downloading $vm_name... "
    
    # Find the most recent OVA with matching name (sort by creation time desc, take first)
    ova_uuid=$(jq -r --arg tag "$ova_name" \
      '.entities[] | select(.info.name==$tag) | {uuid: .metadata.uuid, created: .metadata.creation_time}' <<< "$ovas_json" | \
      jq -r -s 'sort_by(.created) | reverse | .[0].uuid // empty')
    
    if [[ -n "$ova_uuid" && "$ova_uuid" != "null" && "$ova_uuid" != "empty" ]]; then
      outfile="$DOWNLOAD_DIR/${vm_uuid}.ova"
      
      # Use curl with better error handling
      if curl -k -u "$USER:$PASS" -L \
        -H 'Accept: application/octet-stream' \
        "https://$PRISM/api/nutanix/v3/ovas/$ova_uuid/file" \
        -o "$outfile" --fail --show-error; then
        
        if [[ -s "$outfile" ]]; then
          echo "✅ Downloaded"
        else
          echo "✗ Failed (empty file)"
          rm -f "$outfile"
        fi
      else
        echo "✗ Download failed"
        rm -f "$outfile"
      fi
    else
      echo "✗ OVA not found"
      echo "   Looking for OVA named: $ova_name"
      echo "   Available OVAs matching this name:"
      jq -r --arg tag "$ova_name" \
        '.entities[] | select(.info.name==$tag) | "   - \(.info.name) (\(.metadata.uuid)) created: \(.metadata.creation_time)"' <<< "$ovas_json"
      echo "   All available OVAs:"
      jq -r '.entities[] | "   - \(.info.name) (\(.metadata.uuid))"' <<< "$ovas_json" | head -5
    fi
  done
  
  echo ""
  echo "Downloads completed. Files saved to: $DOWNLOAD_DIR"
  
  # Ask if user wants to delete OVAs from Prism Central
  echo ""
  read -p "Do you want to delete the exported OVAs from Prism Central? (y/N): " delete_choice
  if [[ "$delete_choice" =~ ^[Yy] ]]; then
    delete_ovas_from_prism "$ovas_json"
  fi
else
  # If user doesn't want to download, still offer to delete OVAs from Prism Central
  echo ""
  read -p "Do you want to delete the exported OVAs from Prism Central? (y/N): " delete_choice
  if [[ "$delete_choice" =~ ^[Yy] ]]; then
    # Fetch OVA list since we didn't do it for download
    echo ""
    echo "Fetching OVA list from Prism Central..."
    ovas_json=$(curl -s -k -u "$USER:$PASS" \
      -X POST "https://$PRISM/api/nutanix/v3/ovas/list" \
      -H 'Content-Type: application/json' \
      -d '{"kind":"ova","length":1000,"offset":0,"sort_attribute":"name","sort_order":"ASCENDING"}')
    
    delete_ovas_from_prism "$ovas_json"
  fi
fi

echo ""
echo "Export tasks log: $TASKS_FILE"
echo "Process completed!"