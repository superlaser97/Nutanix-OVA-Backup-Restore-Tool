#!/usr/bin/env bash

# THINGS TO FIX:
# - Check if VMs are powered off before export, show warning if not and exit

##############################################################
# export_ova.sh
# ----------------------------------------------------------
# Exports VMs from a Nutanix cluster to OVA files via REST API.
# Workflow:
#   Phase 1: Fetch & Filter
#   Phase 2: Confirm & Submit
#   Phase 3: Monitor
# Output: CSV log and real-time status table
##############################################################

set -eu

# start timer
start_ts=$(date +%s)

# load credentials (fails if file missing or unreadable)
# expects .nutanix_creds exporting PRISM, USER, PASS
source .nutanix_creds || { echo "Credentials file not found or unreadable"; exit 1; }

######################## Configuration ########################
# Polling interval for status checks (in seconds)
POLL_INTERVAL=3

# Column widths for table display
DEFAULT_NAME_WIDTH=7    # minimum VM name column width
UUID_DISPLAY_LENGTH=10  # number of uuid chars to display
UUID_COL_WIDTH=$(( UUID_DISPLAY_LENGTH + 3 ))  # add '...'
PROJECT_COL_WIDTH=15

# File outputs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_EXPORT_TASKS_FILE="$SCRIPT_DIR/vm_export_tasks.csv"
################################################################

#### Prerequisites ####
command -v jq   >/dev/null || { echo "Please install jq (apt install jq)"; exit 1; }
command -v curl >/dev/null || { echo "Please install curl (apt install curl)"; exit 1; }

#### Initialize tasks CSV ####
echo "Initializing export tasks file..."
printf "VM_NAME,VM_UUID,PROJECT_NAME,TASK_UUID,OVA_NAME
" > "$VM_EXPORT_TASKS_FILE"

#### Phase 1: Fetch & filter VMs ####
echo -e "
📋 Fetching and filtering project-assigned VMs from $PRISM…"
vms_json=$(curl -s -k -u "$USER:$PASS" \
  -X POST "https://$PRISM/api/nutanix/v3/vms/list" \
  -H 'Content-Type: application/json' \
  -d '{"length":1000}')

declare -a vm_names vm_uuids vm_projects
for (( i=0; i<$(jq '.entities | length' <<< "$vms_json"); i++ )); do
  name=$(jq -r ".entities[$i].status.name" <<< "$vms_json")
  uuid=$(jq -r ".entities[$i].metadata.uuid" <<< "$vms_json")
  proj=$(jq -r ".entities[$i].metadata.project_reference.name // empty" <<< "$vms_json")
  if [[ -n "$proj" && "$proj" != "_internal" ]]; then
    vm_names+=("$name")
    vm_uuids+=("$uuid")
    vm_projects+=("$proj")
  fi
done

if [[ ${#vm_names[@]} -eq 0 ]]; then
  echo "No qualifying VMs found. Exiting."
  exit 0
fi

# Compute name column width dynamically
dynamic_name_w=$DEFAULT_NAME_WIDTH
for nm in "${vm_names[@]}"; do
  (( ${#nm} > dynamic_name_w )) && dynamic_name_w=${#nm}
done
NAME_COL_WIDTH=$(( dynamic_name_w + 2 ))  # add padding

# Print initial table
table_header_fmt="%-${NAME_COL_WIDTH}s %-${UUID_COL_WIDTH}s %-${PROJECT_COL_WIDTH}s"
echo -e "
The following VMs will be exported:"
printf "$table_header_fmt\n" "VM_NAME" "VM_UUID" "PROJECT"
printf -- "$(printf '%*s' $((NAME_COL_WIDTH+UUID_COL_WIDTH+PROJECT_COL_WIDTH+2)) '-' | tr ' ' '-')\n"
for idx in "${!vm_names[@]}"; do
  printf "$table_header_fmt\n" \
    "${vm_names[idx]}" \
    "${vm_uuids[idx]:0:UUID_DISPLAY_LENGTH}..." \
    "${vm_projects[idx]}"
done

#### Phase 2: Confirm & submit exports ####
if [[ -t 0 ]]; then
  # only prompt if stdin is a terminal
  read -p $'\nProceed with export? (y/N) ' confirm
  if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Export aborted."
    exit 0
  fi
else
  echo "No TTY detected, auto-proceeding with export."
fi

echo -e "
Submitting export requests..."
declare -A task_map name_map project_map
for idx in "${!vm_names[@]}"; do
  name="${vm_names[idx]}"
  uuid="${vm_uuids[idx]}"
  proj="${vm_projects[idx]}"
  echo -n "→ $name… "
  resp=$(curl -s -k -u "$USER:$PASS" \
    -X POST "https://$PRISM/api/nutanix/v3/vms/$uuid/export" \
    -H 'Content-Type: application/json' \
    -d '{"disk_file_format":"QCOW2","name":"'"$uuid"'"}')
  task_uuid=$(jq -r '.task_uuid // empty' <<< "$resp")
  if [[ -n "$task_uuid" ]]; then
    echo "Task UUID=$task_uuid"
    task_map["$uuid"]=$task_uuid
    name_map["$uuid"]=$name
    project_map["$uuid"]=$proj
    printf '%s,%s,%s,%s,%s
' "$name" "$uuid" "$proj" "$task_uuid" "$uuid" >> "$VM_EXPORT_TASKS_FILE"
  else
    echo "✗ Failed to submit"
  fi
done

#### Phase 3: Monitor export progress ####
echo -e "
⏳ Tracking export progress (Ctrl+C to stop)…"
declare -A status_map pct_map

while :; do
  clear
  echo "Export Status:"
  printf "$table_header_fmt %-10s %-10s\n" "VM_NAME" "VM_UUID" "PROJECT" "PROGRESS" "STATUS"
  printf -- "$(printf '%*s' $((NAME_COL_WIDTH+UUID_COL_WIDTH+PROJECT_COL_WIDTH+25)) '-' | tr ' ' '-')\n"

  # 1) Poll each task and print its status
  for vm_uuid in "${!task_map[@]}"; do
    task_json=$(curl -s -k -u "$USER:$PASS" \
      -X GET "https://$PRISM/api/nutanix/v3/tasks/${task_map[$vm_uuid]}" \
      -H 'Accept: application/json')
    status=$(jq -r '.status' <<< "$task_json")
    pct=$(jq -r '.percentage_complete // 0' <<< "$task_json")
    status_map[$vm_uuid]="$status"
    pct_map[$vm_uuid]="$pct"

    printf "%-${NAME_COL_WIDTH}s %-${UUID_COL_WIDTH}s %-${PROJECT_COL_WIDTH}s %3s%%     %s\n" \
      "${name_map[$vm_uuid]}" \
      "${vm_uuid:0:UUID_DISPLAY_LENGTH}..." \
      "${project_map[$vm_uuid]}" \
      "$pct" \
      "$status"
  done

  # 2) Check if *all* tasks have SUCCEEDED
  all_succeeded=true
  for s in "${status_map[@]}"; do
    if [[ "$s" != "SUCCEEDED" ]]; then
      all_succeeded=false
      break
    fi
  done

  # 3) Only break out once every task is SUCCEEDED
  $all_succeeded && break

  sleep $POLL_INTERVAL
done

echo -e "
✅ All export tasks succeeded. Details in: $VM_EXPORT_TASKS_FILE"

# compute elapsed time
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
hours=$(( elapsed / 3600 ))
mins=$(( (elapsed % 3600) / 60 ))
secs=$(( elapsed % 60 ))

# print it out
printf "Completed in %dh %dmin %ds\n" "$hours" "$mins" "$secs"
