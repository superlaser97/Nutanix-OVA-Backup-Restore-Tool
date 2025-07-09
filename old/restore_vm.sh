#!/usr/bin/env bash

##############################################################
# restore_vm.sh
# ----------------------------------------------------------
# Restores VMs from OVA files previously exported via export_ova.sh
# and uploaded via upload_ova.sh. Fetches VM specs, updates network
# references, and re-creates VMs under their original names.
# Logs task details and provides live progress tracking.
#
# Workflow:
#   +---------------------------------------------------------+
#   | Phase 1: Setup & Validation                             |
#   |   - Load credentials                                    |
#   |   - Verify CLI tools (jq, curl)                         |
#   |   - Locate OVA export and upload logs                   |
#   +---------------------------------------------------------+
#                  |
#                  v
#   +---------------------------------------------------------+
#   | Phase 2: Resource Mapping                               |
#   |   - Build maps of subnets, clusters, projects, OVAs     |
#   +---------------------------------------------------------+
#                  |
#                  v
#   +---------------------------------------------------------+
#   | Phase 3: Submit Restore Requests                        |
#   |   - Read vm_export_tasks.csv                            |
#   |   - For each VM:                                        |
#   |       * Fetch VM spec from OVA                          |
#   |       * Update NIC subnet UUIDs                         |
#   |       * Assemble payload with original VM name & project|
#   |       * POST to /vms to create VM                       |
#   |   - Log VM_NAME, PROJECT_NAME, OVA_UUID, NEW_VM_UUID,   |
#   |     TASK_UUID                                           |
#   +---------------------------------------------------------+
#                  |
#                  v
#   +---------------------------------------------------------+
#   | Phase 4: Monitor Restores                               |
#   |   - Poll each task until SUCCEEDED or FAILED            |
#   |   - Display live status table                          |
#   +---------------------------------------------------------+
##############################################################

set -eu

# start timer
start_ts=$(date +%s)

####── Phase 1: Setup & Validation ──####
source .nutanix_creds || { echo "ERROR: credentials file missing"; exit 1; }
for cmd in jq curl; do
  command -v "$cmd" >/dev/null || { echo "Please install $cmd"; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_TASKS_CSV="$SCRIPT_DIR/vm_export_tasks.csv"
UPLOAD_LOG_CSV="$SCRIPT_DIR/upload_tasks.csv"
[[ -f "$EXPORT_TASKS_CSV" ]] || { echo "ERROR: missing $EXPORT_TASKS_CSV"; exit 1; }
[[ -f "$UPLOAD_LOG_CSV" ]]  || { echo "ERROR: missing $UPLOAD_LOG_CSV";  exit 1; }

# Prepare restore log
RESTORE_LOG="$SCRIPT_DIR/restore_tasks.csv"
echo "VM_NAME,PROJECT_NAME,OVA_UUID,NEW_VM_UUID,TASK_UUID" > "$RESTORE_LOG"

####── Phase 2: Resource Mapping ──####
# Build associative map: fetches endpoint list and populates Bash array
# Args: $1=endpoint, $2=jq name key, $3=jq uuid key, $4=array name
# Build associative map: fetches endpoint list and populates Bash associative array
# Args: $1=endpoint, $2=kind for the JSON payload, $3=JSON path to name, $4=JSON path to uuid, $5=name of the assoc array to create
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

  # declare the associative array in the current shell
  eval "declare -gA $map_name=()"

  # populate it in the current shell via process substitution
  while IFS='=' read -r name uuid; do
    # quote name in case it has spaces
    eval "$map_name[\"\$name\"]=\"\$uuid\""
  done < <(
    jq -r ".entities[] | .${name_key} + \"=\" + .${uuid_key}" <<<"$json"
  )
}

# Build maps for subnets, clusters, projects, and OVAs
build_map "subnets"  "subnet"  "status.name"      "metadata.uuid" SUBNET_MAP 1000
build_map "clusters" "cluster" "spec.name"        "metadata.uuid" CLUSTER_MAP 1000
build_map "projects" "project" "status.name"      "metadata.uuid" PROJECT_MAP   100
build_map "ovas"     "ova"     "info.name"        "metadata.uuid" OVA_MAP     1000

####── Phase 3: Submit Restore Requests ──####
while IFS=',' read -r vm_name vm_uuid project_name task_uuid export_uuid; do
  [[ "$vm_name" == "VM_NAME" ]] && continue

  # Look up the OVA's UUID by the exported VM UUID
  ova_uuid="${OVA_MAP[$export_uuid]:-}"
  if [[ -z "$ova_uuid" ]]; then
    echo "  OVA for export UUID $export_uuid not found; skipping"
    continue
  fi

  # Fetch original VM spec from the OVA
  vm_spec_json=$(curl -s -k -u "$USER:$PASS" \
    -X GET "https://$PRISM/api/nutanix/v3/ovas/$ova_uuid/vm_spec" \
    -H 'Content-Type: application/json')
  spec=$(jq '.vm_spec.spec' <<< "$vm_spec_json")

  # Update NIC subnet UUIDs using SUBNET_MAP
  updated_nics=()
  while read -r nic; do
    name=$(jq -r '.subnet_reference.name // empty' <<< "$nic")
    if [[ -n "$name" && -n "${SUBNET_MAP[$name]}" ]]; then
      new_uuid=${SUBNET_MAP[$name]}
      nic=$(jq --arg uuid "$new_uuid" '.subnet_reference.uuid = $uuid' <<< "$nic")
    fi
    updated_nics+=("$nic")
  done < <(jq -c '.resources.nic_list[]?' <<< "$spec")

  if [[ ${#updated_nics[@]} -gt 0 ]]; then
    nic_array=$(printf '%s\n' "${updated_nics[@]}" | jq -s '.')
    spec=$(jq --argjson nics "$nic_array" '.resources.nic_list = $nics' <<< "$spec")
  fi

  # Assemble VM creation payload
  payload=$(jq -n \
    --arg name "$vm_name" \
    --arg proj_uuid "${PROJECT_MAP[$project_name]:-}" \
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
  create_resp=$(curl -s -k -u "$USER:$PASS" \
    -X POST "https://$PRISM/api/nutanix/v3/vms" \
    -H 'Content-Type: application/json' \
    -d "$payload")

  new_uuid=$(jq -r '.metadata.uuid // empty' <<< "$create_resp")
  task_id=$(jq -r '.status.execution_context.task_uuid // empty' <<< "$create_resp")

  if [[ -n "$new_uuid" && -n "$task_id" ]]; then
    echo "$vm_name,$project_name,$ova_uuid,$new_uuid,$task_id" >> "$RESTORE_LOG"
  else
    echo "  Failed to submit restore for $vm_name"
    echo "$create_resp" | jq .
  fi
done < <(tail -n +2 "$EXPORT_TASKS_CSV")

####── Phase 4: Monitor Restores ──####
declare -A TASKS STATUS PROGRESS

# Load tasks
while IFS=',' read -r vm project ova newvm task; do
  [[ "$vm" == "VM_NAME" ]] && continue
  TASKS["$vm"]=$task
  STATUS["$vm"]="PENDING"
  PROGRESS["$vm"]=0
done < "$RESTORE_LOG"

NUM_VMS=${#TASKS[@]}
# table height = header(1) + separator(1) + N rows
TABLE_HEIGHT=$((NUM_VMS + 2))

# Print header + empty rows once
printf "%-25s %-10s %-8s\n" "VM_NAME" "STATUS" "PROGRESS"
printf "%0.s-" $(seq 1 50); echo
for vm in "${!TASKS[@]}"; do
  printf "%-25s %-10s %-8s\n" "$vm" "${STATUS[$vm]}" "${PROGRESS[$vm]}%"
done

# Poll loop
while ((${#TASKS[@]})); do
  sleep 5

  # Update each task’s status/progress
  for vm in "${!TASKS[@]}"; do
    id=${TASKS[$vm]}
    tjson=$(curl -s -k -u "$USER:$PASS" \
      -X GET "https://$PRISM/api/nutanix/v3/tasks/$id")
    st=$(jq -r '.status' <<<"$tjson")
    pc=$(jq -r '.percentage_complete // 0' <<<"$tjson")
    STATUS["$vm"]=$st
    PROGRESS["$vm"]=$pc

    # remove completed tasks
    if [[ "$st" =~ SUCCEEDED|FAILED ]]; then
      unset TASKS["$vm"]
    fi
  done

  # Move cursor up to the start of the table
  printf "\033[%dA" "$TABLE_HEIGHT"

  # Re-print the table in-place
  printf "%-25s %-10s %-8s\n" "VM_NAME" "STATUS" "PROGRESS"
  printf "%0.s-" $(seq 1 50); echo
  for vm in "${!STATUS[@]}"; do
    printf "%-25s %-10s %-8s\n" "$vm" "${STATUS[$vm]}" "${PROGRESS[$vm]}%"
  done
done

echo
echo "✅ All restores complete. See $RESTORE_LOG for details."

# compute elapsed time
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
hours=$(( elapsed / 3600 ))
mins=$(( (elapsed % 3600) / 60 ))
secs=$(( elapsed % 60 ))

printf "Completed in %dh %dmin %ds\n" "$hours" "$mins" "$secs"