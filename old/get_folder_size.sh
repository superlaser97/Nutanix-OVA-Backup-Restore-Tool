# get_folder_size.sh
LATEST_DIR=$(ls -dt ./vm-export-* 2>/dev/null | head -n1)
[[ -d "$LATEST_DIR" ]] || { echo "ERROR: no vm-export-* folder found"; exit 1; }

du -hs $LATEST_DIR
