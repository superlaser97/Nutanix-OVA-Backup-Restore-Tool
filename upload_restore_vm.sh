#!/usr/bin/env bash

##############################################################
# upload_restore_vm.sh
# ----------------------------------------------------------
# Lists available restore points (vm-export-* folders) in the
# current directory, allows navigation and selection, and
# displays details (VMs) for the selected restore point.
##############################################################

# set -euo pipefail  # Disabled for robust key handling

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find all vm-export-* folders
mapfile -t RESTORE_POINTS < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name 'vm-export-*' | sort)

if [[ ${#RESTORE_POINTS[@]} -eq 0 ]]; then
  echo "No restore points (vm-export-*) found in $SCRIPT_DIR."
  exit 0
fi

# Helper: read a single key (arrow keys, W/S, Enter)
read_key() {
  local key
  IFS= read -rsn1 key
  if [[ "$key" == $'\x0d' || "$key" == $'\x0a' || "$key" == "" ]]; then
    echo "ENTER"
    return
  fi
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn1 key
    if [[ "$key" == "[" ]]; then
      IFS= read -rsn1 key
      case "$key" in
        "A") echo "UP" ;;
        "B") echo "DOWN" ;;
        "C") echo "RIGHT" ;;
        "D") echo "LEFT" ;;
        *) echo "UNKNOWN" ;;
      esac
    else
      echo "UNKNOWN"
    fi
  else
    echo "$key"
  fi
}

# UI: Show restore points table with navigation
show_restore_points() {
  clear
  echo "Available Restore Points"
  printf "%-30s %-20s %-10s\n" "RESTORE POINT" "CREATED" "#OVAs"
  printf '%0.s-' $(seq 1 65); echo
  for idx in "${!RESTORE_POINTS[@]}"; do
    folder_name="$(basename "${RESTORE_POINTS[idx]}")"
    if stat --version >/dev/null 2>&1; then
      created="$(stat -c '%y' "${RESTORE_POINTS[idx]}" | cut -d'.' -f1)"
    else
      created="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "${RESTORE_POINTS[idx]}")"
    fi
    num_ovas=$(find "${RESTORE_POINTS[idx]}" -maxdepth 1 -type f -name '*.ova' | wc -l)
    local highlight=""
    [[ $idx -eq $1 ]] && highlight="\033[7m"
    printf "${highlight}%-30s %-20s %-10s\033[0m\n" "$folder_name" "$created" "$num_ovas"
  done
  echo
  echo "Use Up/Down arrows or W/S to select. ENTER to select for upload, Q to view details."
}

# UI: Show details of selected restore point
show_restore_point_details() {
  local dir="$1"
  clear
  folder_name="$(basename "$dir")"
  echo "Restore Point: $folder_name"
  echo
  csv="$dir/vm_export_tasks.csv"
  if [[ ! -f "$csv" ]]; then
    echo "No vm_export_tasks.csv found in $dir."
    echo "Press any key to return."
    read -rsn1
    return
  fi
  # Read and sort VMs by project then name
  mapfile -t vm_lines < <(tail -n +2 "$csv")
  if [[ ${#vm_lines[@]} -eq 0 ]]; then
    echo "No VMs found in this restore point."
    echo "Press any key to return."
    read -rsn1
    return
  fi
  # Use ASCII unit separator for robust sorting
  DELIM=$'\x1F'
  combined=()
  for line in "${vm_lines[@]}"; do
    IFS=',' read -r vm_name vm_uuid project_name _ <<< "$line"
    combined+=("${project_name}${DELIM}${vm_name}${DELIM}${vm_uuid}")
  done
  IFS=$'\n' sorted_combined=($(sort <<<"${combined[*]}"))
  unset IFS
  sorted_vms=()
  sorted_projects=()
  sorted_uuids=()
  for entry in "${sorted_combined[@]}"; do
    IFS="$DELIM" read -r project name uuid <<< "$entry"
    sorted_projects+=("$project")
    sorted_vms+=("$name")
    sorted_uuids+=("$uuid")
  done
  # Pagination setup
  VMS_PER_PAGE=10
  total_vms=${#sorted_vms[@]}
  total_pages=$(( (total_vms + VMS_PER_PAGE - 1) / VMS_PER_PAGE ))
  local page=0
  local details_cursor=0
  while true; do
    clear
    echo "Restore Point: $folder_name"
    echo
    printf "%-25s %-40s %-20s\n" "VM_NAME" "VM_UUID" "PROJECT"
    printf '%0.s-' $(seq 1 90); echo
    start_idx=$((page * VMS_PER_PAGE))
    end_idx=$((start_idx + VMS_PER_PAGE - 1))
    (( end_idx >= total_vms )) && end_idx=$((total_vms - 1))
    for idx in $(seq $start_idx $end_idx); do
      local highlight=""
      [[ $idx -eq $details_cursor ]] && highlight="\033[7m"
      printf "${highlight}%-25s %-40s %-20s\033[0m\n" "${sorted_vms[idx]}" "${sorted_uuids[idx]}" "${sorted_projects[idx]}"
    done
    echo
    echo "Page $((page+1)) of $total_pages (VMs $((start_idx+1))-$((end_idx+1)))"
    echo "Use Up/Down (W/S/arrows) to move, Left/Right (A/D/arrows) to change page. Press any key to return."
    read -rsn1
    return
  done
}

# Confirmation page for restore point selection
confirm_restore_point() {
  local dir="$1"
  clear
  folder_name="$(basename "$dir")"
  echo "You have selected the following restore point:"
  echo
  echo "  $folder_name"
  echo
  echo "Are you sure you want to proceed with this restore point?"
  echo "(Y)es to continue, (N)o to go back."
  while true; do
    read -rsn1 key
    case "$key" in
      "y"|"Y") return 0 ;;
      "n"|"N") return 1 ;;
    esac
  done
}

# OVA upload stage: show upload table (no upload logic yet)
upload_ova_stage() {
  local dir="$1"
  local csv="$dir/vm_export_tasks.csv"
  local folder_name="$(basename "$dir")"
  mapfile -t vm_lines < <(tail -n +2 "$csv")
  declare -a VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS
  local -a MISSING_FILES
  for line in "${vm_lines[@]}"; do
    IFS=',' read -r vm_name _ project_name _ ova_name <<< "$line"
    VM_NAMES+=("$vm_name")
    PROJECTS+=("$project_name")
    OVA_FILES+=("$ova_name.ova")
    STATUS+=("PENDING")
    PROGRESS+=("0%")
  done

  # Upload logic
  CHUNK_SIZE=$((100 * 1024 * 1024))
  POLL_INTERVAL=2
  for i in "${!OVA_FILES[@]}"; do
    local ova_file="$dir/${OVA_FILES[i]}"
    local vm_name="${VM_NAMES[i]}"
    local project="${PROJECTS[i]}"
    if [[ ! -f "$ova_file" ]]; then
      STATUS[i]="MISSING"
      PROGRESS[i]="0%"
      MISSING_FILES+=("${OVA_FILES[i]}")
      print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
      continue
    fi
    STATUS[i]="GENERATING_SHA1"
    PROGRESS[i]="0%"
    print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
    filesize=$(stat -c%s "$ova_file")
    full_cs=$(sha1sum "$ova_file" | cut -d' ' -f1)
    STATUS[i]="CREATING_ENTITY"
    PROGRESS[i]="0%"
    print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
    create_resp=$(curl -s -k -u "$USER:$PASS" \
      -X POST "https://${PRISM}/api/nutanix/v3/ovas" \
      -H 'Content-Type: application/json' \
      -d '{"name":"'"${OVA_FILES[i]%.ova}"'","upload_length":'$filesize',"checksum":{"checksum_algorithm":"SHA_1","checksum_value":"'$full_cs'"}}')
    task_uuid=$(jq -r '.task_uuid // empty' <<<"$create_resp")
    if [[ -z "$task_uuid" ]]; then
      STATUS[i]="FAILED"
      PROGRESS[i]="0%"
      print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
      continue
    fi
    # Wait for OVA UUID
    STATUS[i]="WAITING_UUID"
    PROGRESS[i]="0%"
    print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
    ova_uuid=""
    while [[ -z "$ova_uuid" ]]; do
      task_json=$(curl -s -k -u "$USER:$PASS" \
        -X GET "https://${PRISM}/api/nutanix/v3/tasks/${task_uuid}" \
        -H 'Accept: application/json')
      ova_uuid=$(jq -r '.entity_reference_list[0].uuid // empty' <<<"$task_json")
      if [[ "$(jq -r '.status' <<<"$task_json")" == "FAILED" ]]; then
        STATUS[i]="FAILED"
        PROGRESS[i]="0%"
        print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
        continue 2
      fi
      sleep 1
    done
    # Upload chunks
    STATUS[i]="UPLOADING"
    PROGRESS[i]="0%"
    print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
    offsets=()
    for (( off=0; off<filesize; off+=CHUNK_SIZE )); do
      offsets+=( "$off" )
    done
    for off in "${offsets[@]}"; do
      bytes=$(( filesize - off < CHUNK_SIZE ? filesize - off : CHUNK_SIZE ))
      tmpf=$(mktemp)
      dd if="$ova_file" of="$tmpf" bs=$CHUNK_SIZE skip=$((off/CHUNK_SIZE)) count=1 status=none
      cs=$(sha1sum "$tmpf" | cut -d' ' -f1)
      curl -s -k -u "$USER:$PASS" \
        -X PUT "https://${PRISM}/api/nutanix/v3/ovas/${ova_uuid}/chunks" \
        -H 'Content-Type: application/octet-stream' \
        -H "X-Nutanix-Checksum-Type:SHA_1" \
        -H "X-Nutanix-Checksum-Bytes:${cs}" \
        -H "X-Nutanix-Content-Length:${bytes}" \
        -H "X-Nutanix-Upload-Offset:${off}" \
        --data-binary @"$tmpf" >/dev/null
      rm -f "$tmpf"
      pct=$(( (off + bytes) * 100 / filesize ))
      PROGRESS[i]="$pct%"
      print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
    done
    # Concatenate
    STATUS[i]="VALIDATING"
    PROGRESS[i]="0%"
    print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
    concat_task=$(curl -s -k -u "$USER:$PASS" \
      -X POST "https://${PRISM}/api/nutanix/v3/ovas/${ova_uuid}/chunks/concatenate" \
      -H 'Accept: application/json' \
      | jq -r '.task_uuid // empty')
    while :; do
      task_json=$(curl -s -k -u "$USER:$PASS" \
        -X GET "https://${PRISM}/api/nutanix/v3/tasks/${concat_task}" \
        -H 'Accept: application/json')
      status_now=$(jq -r '.status' <<<"$task_json")
      pc=$(jq -r '.percentage_complete // 0' <<<"$task_json")
      PROGRESS[i]="$pc%"
      print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
      if [[ $status_now == "SUCCEEDED" ]]; then
        STATUS[i]="COMPLETED"
        break
      elif [[ $status_now == "FAILED" ]]; then
        STATUS[i]="FAILED"
        break
      fi
      sleep $POLL_INTERVAL
    done
    print_upload_table "$folder_name" VM_NAMES PROJECTS OVA_FILES STATUS PROGRESS MISSING_FILES
  done
  # Summary
  clear
  if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
    echo -e "\033[33mWARNING: The following OVA files referenced in the CSV were not found in the folder:\033[0m"
    for f in "${MISSING_FILES[@]}"; do
      echo "  $f"
    done
    echo
  fi
  echo "OVA Upload Stage for Restore Point: $folder_name"
  echo
  printf "%-25s %-20s %-25s %-10s %-8s\n" "VM_NAME" "PROJECT" "OVA_FILE" "STATUS" "PROGRESS"
  printf '%0.s-' $(seq 1 90); echo
  for i in "${!VM_NAMES[@]}"; do
    printf "%-25s %-20s %-25s %-10s %-8s\n" "${VM_NAMES[i]}" "${PROJECTS[i]}" "${OVA_FILES[i]}" "${STATUS[i]}" "${PROGRESS[i]}"
  done
  echo
  echo "All uploads done. Press any key to return."
  read -rsn1
}

# Print upload table helper
print_upload_table() {
  local folder_name="$1"
  local -n VM_NAMES=$2
  local -n PROJECTS=$3
  local -n OVA_FILES=$4
  local -n STATUS=$5
  local -n PROGRESS=$6
  local -n MISSING_FILES=$7
  clear
  if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
    echo -e "\033[33mWARNING: The following OVA files referenced in the CSV were not found in the folder:\033[0m"
    for f in "${MISSING_FILES[@]}"; do
      echo "  $f"
    done
    echo
  fi
  echo "OVA Upload Stage for Restore Point: $folder_name"
  echo
  printf "%-25s %-20s %-25s %-10s %-8s\n" "VM_NAME" "PROJECT" "OVA_FILE" "STATUS" "PROGRESS"
  printf '%0.s-' $(seq 1 90); echo
  for i in "${!VM_NAMES[@]}"; do
    printf "%-25s %-20s %-25s %-10s %-8s\n" "${VM_NAMES[i]}" "${PROJECTS[i]}" "${OVA_FILES[i]}" "${STATUS[i]}" "${PROGRESS[i]}"
  done
  echo
}

# Main navigation loop
cursor=0
while true; do
  show_restore_points $cursor
  key=$(read_key)
  case "$key" in
    "w"|"W"|"UP")
      [[ $cursor -gt 0 ]] && ((cursor--))
      ;;
    "s"|"S"|"DOWN")
      [[ $cursor -lt $((${#RESTORE_POINTS[@]}-1)) ]] && ((cursor++))
      ;;
    "ENTER")
      # Confirmation page and next stage
      if confirm_restore_point "${RESTORE_POINTS[$cursor]}"; then
        upload_ova_stage "${RESTORE_POINTS[$cursor]}"
      fi
      ;;
    "q"|"Q")
      # Show details page
      show_restore_point_details "${RESTORE_POINTS[$cursor]}"
      ;;
    *)
      :
      ;;
  esac

done 