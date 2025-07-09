#!/usr/bin/env bash

##############################################################
# upload_ova.sh
# ----------------------------------------------------------
# Uploads OVA files to a Nutanix cluster based on the
# export tasks CSV located alongside this script,
# reading OVA files from the latest vm-export-* folder,
# and displaying a live table of VM_NAME, PROJECT, OVA_FILE,
# STATUS, and PROGRESS.
#
# Workflow:
#   • Phase 1: Setup & Validation
#   • Phase 2: Locate & Initialize State
#   • Phase 3: Upload & Monitor
##############################################################

set -eu

# start timer
start_ts=$(date +%s)

# Polling interval for status checks (in seconds)
POLL_INTERVAL=5

#### Phase 1: Setup & Validation ####
source .nutanix_creds || { echo "ERROR: credentials file missing"; exit 1; }
CHUNK_SIZE=$((100 * 1024 * 1024))

for cmd in jq curl sha1sum; do
  command -v "$cmd" >/dev/null || { echo "ERROR: install $cmd"; exit 1; }
done

#### Phase 2: Locate & Initialize Upload State ####
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LATEST_DIR=$(ls -dt "$SCRIPT_DIR"/vm-export-* 2>/dev/null | head -n1)
[[ -d "$LATEST_DIR" ]] || { echo "ERROR: no vm-export-* folder found"; exit 1; }

TASKS_CSV="$SCRIPT_DIR/vm_export_tasks.csv"
[[ -f "$TASKS_CSV" ]] || { echo "ERROR: missing vm_export_tasks.csv in $SCRIPT_DIR"; exit 1; }

STATE_FILE="$SCRIPT_DIR/state.json"
jq -n '{files: []}' > "$STATE_FILE"

# Populate state.json with PENDING entries
tail -n +2 "$TASKS_CSV" | while IFS=',' read -r vm_name vm_uuid project task_uuid ova; do
  jq --arg ova "$ova" --arg vm "$vm_name" --arg pr "$project" \
     '.files += [{
        ova_name:   $ova,
        vm_name:    $vm,
        project:    $pr,
        status:     "PENDING",
        progress:    0
      }]' "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
done

CSV_FILE="$SCRIPT_DIR/upload_tasks.csv"
printf "OVA_NAME\n" > "$CSV_FILE"

print_table(){
  local state_file="$1"
  local headers rows cols maxlen fmt_row dash_line i

  headers=( "VM_NAME" "PROJECT" "OVA_FILE" "STATUS" "PROGRESS" )

  mapfile -t rows < <(
    jq -r '.files[] |
            [ .vm_name, .project, .ova_name, .status, (.progress|tostring + "%") ]
          | @tsv' "$state_file"
  )

  for i in "${!headers[@]}"; do
    maxlen[i]=${#headers[i]}
  done

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r -a cols <<<"$row"
    for i in "${!cols[@]}"; do
      (( ${#cols[i]} > maxlen[i] )) && maxlen[i]=${#cols[i]}
    done
  done

  fmt_row=""
  for i in "${!maxlen[@]}"; do
    fmt_row+="%-${maxlen[i]}s"
    (( i < ${#maxlen[@]}-1 )) && fmt_row+="  "
  done
  fmt_row+="\n"

  dash_line="$(printf "$fmt_row" "${maxlen[@]}" | sed 's/./-/g')"

  clear
  printf "$fmt_row" "${headers[@]}"
  printf "%s\n" "$dash_line"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r -a cols <<<"$row"
    printf "$fmt_row" "${cols[@]}"
  done
}

print_table "$STATE_FILE"

#### Phase 3: Upload & Monitor ####
jq -r '.files[].ova_name' "$STATE_FILE" | while read -r ova; do
  FILEPATH="$LATEST_DIR/${ova}.ova"
  [[ -f "$FILEPATH" ]] || { echo "ERROR: missing OVA file $FILEPATH"; exit 1; }
  filesize=$(stat -c%s "$FILEPATH")

  # — GENERATING_SHA1 —
  jq --arg ova "$ova" \
     '(.files[] | select(.ova_name == $ova))
        |= (.status = "GENERATING_SHA1" | .progress = 0)' \
     "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
  print_table "$STATE_FILE"

  full_cs=$(sha1sum "$FILEPATH" | cut -d' ' -f1)

  # — CREATING_ENTITY —
  jq --arg ova "$ova" \
     '(.files[] | select(.ova_name == $ova))
        |= (.status = "CREATING_ENTITY" | .progress = 0)' \
     "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
  print_table "$STATE_FILE"

  create_resp=$(curl -s -k -u "$USER:$PASS" \
    -X POST "https://${PRISM}/api/nutanix/v3/ovas" \
    -H 'Content-Type: application/json' \
    -d '{"name":"'"$ova"'","upload_length":'"$filesize"',"checksum":{"checksum_algorithm":"SHA_1","checksum_value":"'"$full_cs"'"}}')

  task_uuid=$(jq -r '.task_uuid // empty' <<<"$create_resp")
  if [[ -z "$task_uuid" ]]; then
    jq --arg ova "$ova" \
       '(.files[] | select(.ova_name == $ova))
          |= (.status = "FAILED")' \
       "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
    print_table "$STATE_FILE"
    continue
  fi

  # — WAIT FOR OVA UUID —
  ova_uuid=""
  until [[ -n "$ova_uuid" ]]; do
    task_json=$(curl -s -k -u "$USER:$PASS" \
      -X GET "https://${PRISM}/api/nutanix/v3/tasks/${task_uuid}" \
      -H 'Accept: application/json')
    ova_uuid=$(jq -r '.entity_reference_list[0].uuid // empty' <<<"$task_json")
    if [[ "$(jq -r '.status' <<<"$task_json")" == "FAILED" ]]; then
      jq --arg ova "$ova" \
         '(.files[] | select(.ova_name == $ova))
            |= (.status = "FAILED")' \
         "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
      print_table "$STATE_FILE"
      break 2
    fi
    sleep 1
  done

  # — UPLOADING CHUNKS — (parallelized) —
  jq --arg ova "$ova" \
     '(.files[] | select(.ova_name == $ova))
        |= (.status = "UPLOADING" | .progress = 0)' \
     "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
  print_table "$STATE_FILE"

  # function to upload one chunk
  upload_chunk() {
    local off=$1
    local bytes=$(( filesize - off < CHUNK_SIZE ? filesize - off : CHUNK_SIZE ))
    local tmpf cs pct

    tmpf=$(mktemp)
    dd if="$FILEPATH" of="$tmpf" bs=$CHUNK_SIZE skip=$((off/CHUNK_SIZE)) count=1 status=none

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
    jq --arg ova "$ova" --argjson p "$pct" \
       '(.files[] | select(.ova_name == $ova))
          |= (.progress = $p)' \
       "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"

    print_table "$STATE_FILE"
  }

  # build list of offsets
  offsets=()
  for (( off=0; off<filesize; off+=CHUNK_SIZE )); do
    offsets+=( "$off" )
  done

  # throttled parallel uploads
  MAX_JOBS=4
  for off in "${offsets[@]}"; do
    upload_chunk "$off" &
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
      sleep 0.5
    done
  done
  wait

  # — VALIDATING / CONCATENATING —
  jq --arg ova "$ova" \
     '(.files[] | select(.ova_name == $ova))
        |= (.status = "VALIDATING" | .progress = 0)' \
     "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
  print_table "$STATE_FILE"

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

    jq --arg ova "$ova" --argjson p "$pc" \
       '(.files[] | select(.ova_name == $ova))
          |= (.progress = $p)' \
       "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
    print_table "$STATE_FILE"

    if [[ $status_now == "SUCCEEDED" || $status_now == "FAILED" ]]; then
      jq --arg ova "$ova" --arg s "$status_now" \
         '(.files[] | select(.ova_name == $ova))
            |= (.status = $s)' \
         "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
      print_table "$STATE_FILE"
      break
    fi
    sleep $POLL_INTERVAL
  done

  echo "$ova" >> "$CSV_FILE"
done

echo "All uploads done. Log: $CSV_FILE"

# compute elapsed time
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
hours=$(( elapsed / 3600 ))
mins=$(( (elapsed % 3600) / 60 ))
secs=$(( elapsed % 60 ))

printf "Completed in %dh %dmin %ds\n" "$hours" "$mins" "$secs"
