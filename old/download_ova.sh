#!/usr/bin/env bash

##############################################################
# download_ova.sh
# ----------------------------------------------------------
# Downloads OVA files from a Nutanix cluster based on the
# CSV output of export_ova.sh (where OVA_NAME == VM UUID),
# displaying a table of tasks and downloading each OVA
# sequentially with an animated spinner in-table.
# Workflow:
#   Phase 1: Fetch & Prepare Tasks
#   Phase 2: Download Sequentially (table refresh every 2s)
# Output:
#   - vm-export-YYYY-MM-DD_HH-MM-SS/:
#       • vm_export_tasks.csv (copied)
#       • <VM_NAME>.ova files
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

# File outputs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_CSV="$SCRIPT_DIR/vm_export_tasks.csv"
[[ -f "$TASKS_CSV" ]] || { echo "ERROR: Missing tasks file: $TASKS_CSV"; exit 1; }
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
DOWNLOAD_DIR="$SCRIPT_DIR/vm-export-$TIMESTAMP"
mkdir -p "$DOWNLOAD_DIR"
################################################################

#### Prerequisites ####
command -v jq   >/dev/null || { echo "Please install jq (apt install jq)"; exit 1; }
command -v curl >/dev/null || { echo "Please install curl (apt install curl)"; exit 1; }

#### Phase 1: Fetch & Prepare Tasks ####
echo "Fetching OVA list..."
ovas_json=$(curl -s -k -u "$USER:$PASS" \
  -X POST "https://$PRISM/api/nutanix/v3/ovas/list" \
  -H 'Content-Type: application/json' \
  -d '{"kind":"ova","length":1000,"offset":0,"sort_attribute":"name","sort_order":"ASCENDING"}')

declare -a vm_names vm_projects ova_names ova_uuids status_list progress_list

while IFS=',' read -r vm_name vm_uuid project_name task_uuid ova_name; do
  [[ "$vm_name" == "VM_NAME" ]] && continue
  ova_uuid=$(jq -r --arg tag "$ova_name" \
    '.entities[] | select(.info.name==$tag) | .metadata.uuid' <<< "$ovas_json")
  [[ -z "$ova_uuid" ]] && continue

  vm_names+=("$vm_name")
  vm_projects+=("$project_name")
  ova_names+=("$ova_name")
  ova_uuids+=("$ova_uuid")
  status_list+=("PENDING")
  progress_list+=("0%")
done < "$TASKS_CSV"

[[ ${#ova_names[@]} -gt 0 ]] || { echo "No matching OVAs to download. Exiting."; exit 1; }

# compute column widths
name_col_w=0
for nm in "${vm_names[@]}"; do
  (( ${#nm} > name_col_w )) && name_col_w=${#nm}
done
name_col_w=$((name_col_w + 2))

proj_col_w=15
file_col_w=0
for fn in "${ova_names[@]}"; do
  (( ${#fn} > file_col_w )) && file_col_w=${#fn}
done
file_col_w=$((file_col_w + 2))

status_col_w=11
progress_col_w=2

# header format
header_fmt="%-${name_col_w}s %-${proj_col_w}s %-${file_col_w}s %-${status_col_w}s %${progress_col_w}s"

draw_table(){
  # only clear if we're on a real terminal
  if [[ -t 1 ]]; then
    clear
  fi
  printf "Downloading...\n"
  printf "$header_fmt\n" "VM_NAME" "PROJECT" "OVA_FILE" "STATUS" "%"
  printf -- "$(printf '%*s' $((name_col_w+proj_col_w+file_col_w+status_col_w+progress_col_w+4)) '-' | tr ' ' '-')\n"
  for i in "${!ova_names[@]}"; do
    printf "$header_fmt\n" \
      "${vm_names[i]}" \
      "${vm_projects[i]}" \
      "${ova_names[i]}" \
      "${status_list[i]}" \
      "${progress_list[i]}"
  done
}

declare -a spinner=( '|' '/' '-' '\' )

draw_table

#### Phase 2: Download Sequentially ####
for idx in "${!ova_names[@]}"; do
  outfile="$DOWNLOAD_DIR/${ova_names[idx]}.ova"
  status_list[idx]="DOWNLOADING"
  progress_list[idx]=" "
  draw_table

  curl -s -k -u "$USER:$PASS" -L \
    -H 'Accept: application/octet-stream' \
    "https://$PRISM/api/nutanix/v3/ovas/${ova_uuids[idx]}/file" \
    > "$outfile" &
  dl_pid=$!

  spin_i=0
  while kill -0 "$dl_pid" 2>/dev/null; do
    progress_list[idx]="${spinner[spin_i]}"
    draw_table
    spin_i=$(((spin_i+1)%${#spinner[@]}))
    sleep $POLL_INTERVAL
  done
  wait "$dl_pid"

  if [[ -s "$outfile" ]]; then
    status_list[idx]="COMPLETED"
    progress_list[idx]="100%"
  else
    status_list[idx]="FAILED"
    progress_list[idx]="0%"
  fi
  draw_table
done

echo -e "\nAll downloads finished. See directory: $DOWNLOAD_DIR"

end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
h=$((elapsed / 3600)); m=$(((elapsed % 3600) / 60)); s=$((elapsed % 60))
printf "Completed in %dh %dmin %ds\n" "$h" "$m" "$s"
