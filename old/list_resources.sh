#!/usr/bin/env bash

##############################################################
# list_resources.sh
# ----------------------------------------------------------
# Interactive menu script to list Nutanix resources in table
# format. Provides options to view VMs with their details
# and subnets with relevant information.
#
# Features:
#   - Interactive menu system
#   - Formatted table output
#   - VM details: name, subnet, CPU, storage
#   - Subnet details: name, vlan, gateway, prefix
#   - Error handling and validation
##############################################################

set -eu

# load credentials (fails if file missing or unreadable)
# expects .nutanix_creds exporting PRISM, USER, PASS
source .nutanix_creds || { echo "Credentials file not found or unreadable"; exit 1; }

# locate script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# prerequisites
command -v jq   >/dev/null || { echo "Please install jq (apt install jq)"; exit 1; }
command -v curl >/dev/null || { echo "Please install curl (apt install curl)"; exit 1; }

# Colors for menu
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display menu
show_menu() {
    clear
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}    Nutanix Resource Lister     ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    echo -e "${GREEN}1.${NC} List all VMs with details"
    echo -e "${GREEN}2.${NC} List all subnets"
    echo -e "${GREEN}3.${NC} Exit"
    echo
    echo -n "Enter your choice (1-3): "
}

# Function to fetch VMs and display in table
list_vms() {
    echo -e "\n${YELLOW}Fetching VM information...${NC}"
    
    # Fetch VMs from API
    vms_json=$(curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM/api/nutanix/v3/vms/list" \
        -H 'Content-Type: application/json' \
        -d '{
            "kind": "vm",
            "length": 1000,
            "offset": 0,
            "sort_attribute": "name",
            "sort_order": "ASCENDING"
        }')
    
    # Check if API call was successful
    if ! jq -e '.entities' <<< "$vms_json" >/dev/null 2>&1; then
        echo -e "${RED}Error: Failed to fetch VMs from API${NC}"
        return 1
    fi
    
    # Process VMs and build table data
    declare -a vm_names vm_projects vm_subnets vm_cpus vm_storage vm_status
    
    count=$(jq '.entities | length' <<< "$vms_json")
    for (( i=0; i<count; i++ )); do
        vm_json=$(jq ".entities[$i]" <<< "$vms_json")
        
        # Extract VM details
        name=$(jq -r '.spec.name // "N/A"' <<< "$vm_json")
        status=$(jq -r '.status.state // "N/A"' <<< "$vm_json")
        
        # Extract project info
        project_uuid=$(jq -r '.metadata.project_reference.uuid // empty' <<< "$vm_json")
        project_name="N/A"
        if [[ -n "$project_uuid" ]]; then
            # Fetch project name
            project_json=$(curl -s -k -u "$USER:$PASS" \
                -X GET "https://$PRISM/api/nutanix/v3/projects/$project_uuid" \
                -H 'Content-Type: application/json')
            project_name=$(jq -r '.spec.name // "N/A"' <<< "$project_json")
        fi
        
        # Extract CPU info
        cpu_cores=$(jq -r '.spec.resources.num_sockets // 0' <<< "$vm_json")
        cpu_per_socket=$(jq -r '.spec.resources.num_vcpus_per_socket // 0' <<< "$vm_json")
        total_cpu=$((cpu_cores * cpu_per_socket))
        
        # Extract storage info (sum of all disk sizes)
        total_storage=0
        disk_count=$(jq '.spec.resources.disk_list | length // 0' <<< "$vm_json")
        for (( d=0; d<disk_count; d++ )); do
            disk_size=$(jq -r ".spec.resources.disk_list[$d].disk_size_mib // 0" <<< "$vm_json")
            total_storage=$((total_storage + disk_size))
        done
        
        # Convert storage to GB
        storage_gb=$((total_storage / 1024))
        
        # Extract subnet info
        subnet_names=()
        nic_count=$(jq '.spec.resources.nic_list | length // 0' <<< "$vm_json")
        for (( n=0; n<nic_count; n++ )); do
            subnet_name=$(jq -r ".spec.resources.nic_list[$n].subnet_reference.name // empty" <<< "$vm_json")
            if [[ -n "$subnet_name" ]]; then
                subnet_names+=("$subnet_name")
            fi
        done
        
        # Join subnet names with comma (no truncation)
        subnet_list=$(IFS=', '; echo "${subnet_names[*]:-N/A}")
        
        # Store in arrays
        vm_names+=("$name")
        vm_projects+=("$project_name")
        vm_subnets+=("$subnet_list")
        vm_cpus+=("$total_cpu")
        vm_storage+=("${storage_gb}GB")
        vm_status+=("$status")
    done
    
    # Sort by project, then by VM name
    # Create temporary array with sort keys
    declare -a sort_keys
    for i in "${!vm_names[@]}"; do
        sort_keys+=("${vm_projects[i]}|${vm_names[i]}|$i")
    done
    
    # Sort the keys
    IFS=$'\n' sorted_keys=($(sort <<<"${sort_keys[*]}"))
    unset IFS
    
    # Reorder arrays based on sorted keys
    declare -a sorted_names sorted_projects sorted_subnets sorted_cpus sorted_storage sorted_status
    for key in "${sorted_keys[@]}"; do
        IFS='|' read -r project name index <<< "$key"
        sorted_names+=("${vm_names[index]}")
        sorted_projects+=("${vm_projects[index]}")
        sorted_subnets+=("${vm_subnets[index]}")
        sorted_cpus+=("${vm_cpus[index]}")
        sorted_storage+=("${vm_storage[index]}")
        sorted_status+=("${vm_status[index]}")
    done
    
    # Replace original arrays with sorted ones
    vm_names=("${sorted_names[@]}")
    vm_projects=("${sorted_projects[@]}")
    vm_subnets=("${sorted_subnets[@]}")
    vm_cpus=("${sorted_cpus[@]}")
    vm_storage=("${sorted_storage[@]}")
    vm_status=("${sorted_status[@]}")
    
    # Calculate column widths (no limits)
    name_width=0
    project_width=0
    subnet_width=0
    
    for i in "${!vm_names[@]}"; do
        (( ${#vm_names[i]} > name_width )) && name_width=${#vm_names[i]}
        (( ${#vm_projects[i]} > project_width )) && project_width=${#vm_projects[i]}
        (( ${#vm_subnets[i]} > subnet_width )) && subnet_width=${#vm_subnets[i]}
    done
    
    # Ensure minimum widths
    name_width=$((name_width + 2))
    project_width=$((project_width + 2))
    subnet_width=$((subnet_width + 2))
    [[ $name_width -lt 12 ]] && name_width=12
    [[ $project_width -lt 10 ]] && project_width=10
    [[ $subnet_width -lt 15 ]] && subnet_width=15
    
    # Display table
    echo -e "\n${GREEN}VM List (${count} VMs found):${NC}"
    echo
    printf "%-${name_width}s %-${project_width}s %-${subnet_width}s %-6s %-8s %-8s\n" "VM_NAME" "PROJECT" "SUBNETS" "CPU" "STORAGE" "STATUS"
    printf "%0.s-" $(seq 1 $((name_width + project_width + subnet_width + 6 + 8 + 8 + 5))); echo
    
    for i in "${!vm_names[@]}"; do
        printf "%-${name_width}s %-${project_width}s %-${subnet_width}s %-6s %-8s %-8s\n" \
            "${vm_names[i]}" \
            "${vm_projects[i]}" \
            "${vm_subnets[i]}" \
            "${vm_cpus[i]}" \
            "${vm_storage[i]}" \
            "${vm_status[i]}"
    done
    
    echo
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r
}

# Function to fetch subnets and display in table
list_subnets() {
    echo -e "\n${YELLOW}Fetching subnet information...${NC}"
    
    # Fetch subnets from API
    subnets_json=$(curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM/api/nutanix/v3/subnets/list" \
        -H 'Content-Type: application/json' \
        -d '{
            "kind": "subnet",
            "length": 1000,
            "offset": 0,
            "sort_attribute": "name",
            "sort_order": "ASCENDING"
        }')
    
    # Check if API call was successful
    if ! jq -e '.entities' <<< "$subnets_json" >/dev/null 2>&1; then
        echo -e "${RED}Error: Failed to fetch subnets from API${NC}"
        return 1
    fi
    
    # Process subnets and build table data
    declare -a subnet_names subnet_vlans subnet_gateways subnet_prefixes subnet_clusters
    
    count=$(jq '.entities | length' <<< "$subnets_json")
    for (( i=0; i<count; i++ )); do
        subnet_json=$(jq ".entities[$i]" <<< "$subnets_json")
        
        # Extract subnet details
        name=$(jq -r '.spec.name // "N/A"' <<< "$subnet_json")
        vlan=$(jq -r '.spec.resources.vlan_id // "N/A"' <<< "$subnet_json")
        gateway=$(jq -r '.spec.resources.gateway_ip // "N/A"' <<< "$subnet_json")
        prefix=$(jq -r '.spec.resources.subnet_ip // "N/A"' <<< "$subnet_json")
        
        # Extract cluster name
        cluster_uuid=$(jq -r '.spec.resources.cluster_reference.uuid // empty' <<< "$subnet_json")
        cluster_name="N/A"
        if [[ -n "$cluster_uuid" ]]; then
            # Fetch cluster name
            cluster_json=$(curl -s -k -u "$USER:$PASS" \
                -X GET "https://$PRISM/api/nutanix/v3/clusters/$cluster_uuid" \
                -H 'Content-Type: application/json')
            cluster_name=$(jq -r '.spec.name // "N/A"' <<< "$cluster_json")
        fi
        
        # Store in arrays
        subnet_names+=("$name")
        subnet_vlans+=("$vlan")
        subnet_gateways+=("$gateway")
        subnet_prefixes+=("$prefix")
        subnet_clusters+=("$cluster_name")
    done
    
    # Calculate column widths
    name_width=0
    gateway_width=0
    prefix_width=0
    cluster_width=0
    
    for i in "${!subnet_names[@]}"; do
        (( ${#subnet_names[i]} > name_width )) && name_width=${#subnet_names[i]}
        (( ${#subnet_gateways[i]} > gateway_width )) && gateway_width=${#subnet_gateways[i]}
        (( ${#subnet_prefixes[i]} > prefix_width )) && prefix_width=${#subnet_prefixes[i]}
        (( ${#subnet_clusters[i]} > cluster_width )) && cluster_width=${#subnet_clusters[i]}
    done
    
    # Ensure minimum widths
    name_width=$((name_width + 2))
    gateway_width=$((gateway_width + 2))
    prefix_width=$((prefix_width + 2))
    cluster_width=$((cluster_width + 2))
    [[ $name_width -lt 15 ]] && name_width=15
    [[ $gateway_width -lt 12 ]] && gateway_width=12
    [[ $prefix_width -lt 12 ]] && prefix_width=12
    [[ $cluster_width -lt 12 ]] && cluster_width=12
    
    # Display table
    echo -e "\n${GREEN}Subnet List (${count} subnets found):${NC}"
    echo
    printf "%-${name_width}s %-8s %-${gateway_width}s %-${prefix_width}s %-${cluster_width}s\n" "SUBNET_NAME" "VLAN" "GATEWAY" "PREFIX" "CLUSTER"
    printf "%0.s-" $(seq 1 $((name_width + 8 + gateway_width + prefix_width + cluster_width + 4))); echo
    
    for i in "${!subnet_names[@]}"; do
        printf "%-${name_width}s %-8s %-${gateway_width}s %-${prefix_width}s %-${cluster_width}s\n" \
            "${subnet_names[i]}" \
            "${subnet_vlans[i]}" \
            "${subnet_gateways[i]}" \
            "${subnet_prefixes[i]}" \
            "${subnet_clusters[i]}"
    done
    
    echo
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r
}

# Main menu loop
while true; do
    show_menu
    read -r choice
    
    case $choice in
        1)
            list_vms
            ;;
        2)
            list_subnets
            ;;
        3)
            echo -e "\n${GREEN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "\n${RED}Invalid choice. Please enter 1, 2, or 3.${NC}"
            sleep 2
            ;;
    esac
done 