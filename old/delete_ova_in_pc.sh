#!/usr/bin/env bash

##############################################################
# delete_ova_in_pc.sh
# ----------------------------------------------------------
# Deletes OVA artifacts in Prism Central that were previously
# exported by export_ova.sh, based on vm_export_tasks.csv.
# Workflow:
#   1. Load credentials
#   2. Read exported OVA names from tasks file
#   3. Fetch all OVAs and map names to UUIDs
#   4. Delete matching OVAs via API
##############################################################

set -eu

# start timer
start_ts=$(date +%s)

# load credentials (fails if file missing or unreadable)
# expects .nutanix_creds exporting PRISM, USER, PASS
source .nutanix_creds || { echo "Credentials file not found or unreadable"; exit 1; }

# locate script and tasks file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_FILE="$SCRIPT_DIR/vm_export_tasks.csv"

# prerequisites
command -v jq   >/dev/null || { echo "Please install jq (apt install jq)"; exit 1; }
command -v curl >/dev/null || { echo "Please install curl (apt install curl)"; exit 1; }

echo "→ Reading exported OVA names from $TASKS_FILE…"
declare -A ova_names
while IFS=, read -r vm_name vm_uuid proj task_uuid ova_name; do
  # skip header
  [[ "$vm_name" == "VM_NAME" ]] && continue
  ova_names["$ova_name"]=1
done < "$TASKS_FILE"

if [[ ${#ova_names[@]} -eq 0 ]]; then
  echo "No OVAs listed in $TASKS_FILE. Nothing to delete."
  exit 0
fi

echo "→ Fetching all OVAs from https://$PRISM/api/nutanix/v3/ovas/list…"
ovas_json=$(curl -s -k -u "$USER:$PASS" \
  -X POST "https://$PRISM/api/nutanix/v3/ovas/list" \
  -H 'Content-Type: application/json' \
  -d '{
        "kind": "ova",
        "length": 1000,
        "offset": 0,
        "sort_attribute": "name",
        "sort_order": "ASCENDING"
      }')

echo "→ Mapping OVA names to UUIDs…"
declare -A ova_uuid_map
count=$(jq '.entities | length' <<<"$ovas_json")
for (( i=0; i<count; i++ )); do
  name=$(jq -r ".entities[$i].info.name"       <<<"$ovas_json")
  uuid=$(jq -r ".entities[$i].metadata.uuid"    <<<"$ovas_json")
  ova_uuid_map["$name"]="$uuid"
done

echo -e "\nDeleting exported OVAs:"
for ova in "${!ova_names[@]}"; do
  if uuid="${ova_uuid_map[$ova]:-}"; then
    echo -n "→ $ova (UUID: $uuid)… "
    resp=$(curl -s -k -u "$USER:$PASS" \
      -X DELETE "https://$PRISM/api/nutanix/v3/ovas/$uuid" \
      -H 'Content-Type: application/json')
    # optionally inspect $resp for errors
    echo "deleted."
  else
    echo "→ $ova not found in current OVA list, skipping."
  fi
done

# elapsed time
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
printf "\n✅ Completed in %dh %dmin %ds\n" \
  $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60))
