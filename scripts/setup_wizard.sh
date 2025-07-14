#!/usr/bin/env bash

set -euo pipefail

# Colors for output - improved for better readability
RED='\033[0;31m'        # Red for errors
GREEN='\033[0;32m'      # Green for success
YELLOW='\033[1;33m'     # Bright yellow for warnings
CYAN='\033[0;36m'       # Cyan for info (replaces dark blue)
MAGENTA='\033[0;35m'    # Magenta for headers
BOLD='\033[1m'          # Bold text
DIM='\033[2m'           # Dim text for less important info
UNDERLINE='\033[4m'     # Underline for emphasis
NC='\033[0m'            # No Color

# Status icons
SUCCESS="✅"
ERROR="❌"
WARNING="⚠️"
INFO="ℹ️"
LOADING="🔄"

# Configuration
CREDS_FILE=".nutanix_creds"
BACKUP_SUFFIX=".backup"

# Functions
print_header() {
    echo -e "\n${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}              🛠️  Nutanix OVA Backup/Restore Tool - Setup Wizard${NC}"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}\n"
}

print_section() {
    echo -e "\n${BOLD}${CYAN}▶ $1${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────────────────────────────────────${NC}"
}

print_success() {
    echo -e "${GREEN}${SUCCESS} $1${NC}"
}

print_error() {
    echo -e "${RED}${ERROR} $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}${WARNING} $1${NC}"
}

print_info() {
    echo -e "${CYAN}${INFO} $1${NC}"
}

print_loading() {
    echo -e "${CYAN}${LOADING} $1${NC}"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    print_section "Checking Prerequisites"
    
    local all_good=true
    
    # Check bash version
    if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
        print_error "Bash version 4.0 or higher required. Current: $BASH_VERSION"
        all_good=false
    else
        print_success "Bash version: $BASH_VERSION"
    fi
    
    # Check required commands
    local required_commands=("jq" "curl" "openssl" "base64")
    
    for cmd in "${required_commands[@]}"; do
        if command_exists "$cmd"; then
            local version=""
            case "$cmd" in
                "jq")
                    version=$(jq --version 2>/dev/null || echo "unknown")
                    ;;
                "curl")
                    version=$(curl --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
                    ;;
                "openssl")
                    version=$(openssl version 2>/dev/null | awk '{print $2}' || echo "unknown")
                    ;;
                "base64")
                    version="available"
                    ;;
            esac
            print_success "$cmd: $version"
        else
            print_error "$cmd is not installed or not in PATH"
            all_good=false
        fi
    done
    
    # Check network connectivity
    print_loading "Testing network connectivity..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        print_success "Network connectivity: OK"
    else
        print_warning "Network connectivity test failed. This may affect API connections."
    fi
    
    if [[ "$all_good" == false ]]; then
        echo -e "\n${RED}${ERROR} Prerequisites check failed. Please install missing dependencies.${NC}"
        echo -e "\n${BOLD}Installation instructions:${NC}"
        echo -e "  • Ubuntu/Debian: ${CYAN}sudo apt-get install jq curl openssl coreutils${NC}"
        echo -e "  • CentOS/RHEL:   ${CYAN}sudo yum install jq curl openssl coreutils${NC}"
        echo -e "  • macOS:         ${CYAN}brew install jq curl openssl${NC}"
        return 1
    fi
    
    return 0
}

# Validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Validate hostname/FQDN
validate_hostname() {
    local hostname=$1
    if [[ $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    return 1
}

# Test API connectivity
test_api_connection() {
    local prism=$1
    local user=$2
    local pass=$3
    
    print_loading "Testing API connection to $prism..."
    
    # Test basic connectivity
    if ! curl -s --connect-timeout 10 --max-time 30 -k "https://$prism" >/dev/null 2>&1; then
        print_error "Cannot connect to https://$prism"
        echo -e "  ${YELLOW}Common issues:${NC}"
        echo -e "  • Incorrect IP address or hostname"
        echo -e "  • Firewall blocking connection"
        echo -e "  • Prism Central not running"
        echo -e "  • Network connectivity issues"
        return 1
    fi
    
    # Test API authentication
    local response
    response=$(curl -s --connect-timeout 10 --max-time 30 -k \
        -u "$user:$pass" \
        -X POST \
        "https://$prism/api/nutanix/v3/vms/list" \
        -H 'Content-Type: application/json' \
        -d '{"length":1}' 2>&1)
    
    if [[ $? -eq 0 ]]; then
        # Check if response contains expected fields
        if echo "$response" | jq -e '.entities' >/dev/null 2>&1; then
            print_success "API connection successful"
            local vm_count
            vm_count=$(echo "$response" | jq -r '.metadata.total_matches // 0')
            print_info "Found $vm_count VMs accessible with these credentials"
            return 0
        else
            print_error "API returned unexpected response"
            echo -e "  ${YELLOW}Response:${NC} $response"
            return 1
        fi
    else
        print_error "API authentication failed"
        echo -e "  ${YELLOW}Common issues:${NC}"
        echo -e "  • Incorrect username or password"
        echo -e "  • User account locked or disabled"
        echo -e "  • Insufficient permissions"
        echo -e "  • API endpoint not available"
        return 1
    fi
}

# Collect credentials
collect_credentials() {
    print_section "Nutanix Credentials Setup"
    
    local prism user pass
    
    # Get Prism Central IP/hostname
    while true; do
        echo -e "\n${BOLD}Enter Prism Central IP address or hostname:${NC}"
        read -r prism
        
        if [[ -z "$prism" ]]; then
            print_error "Prism Central address cannot be empty"
            continue
        fi
        
        if validate_ip "$prism" || validate_hostname "$prism"; then
            break
        else
            print_error "Invalid IP address or hostname format"
            echo -e "  ${YELLOW}Examples:${NC}"
            echo -e "  • IP address: 192.168.1.100"
            echo -e "  • Hostname: prism-central.company.com"
        fi
    done
    
    # Get username
    while true; do
        echo -e "\n${BOLD}Enter username:${NC}"
        read -r user
        
        if [[ -z "$user" ]]; then
            print_error "Username cannot be empty"
            continue
        fi
        
        if [[ ${#user} -lt 3 ]]; then
            print_error "Username must be at least 3 characters long"
            continue
        fi
        
        break
    done
    
    # Get password
    while true; do
        echo -e "\n${BOLD}Enter password:${NC}"
        read -rs pass
        echo
        
        if [[ -z "$pass" ]]; then
            print_error "Password cannot be empty"
            continue
        fi
        
        if [[ ${#pass} -lt 6 ]]; then
            print_error "Password must be at least 6 characters long"
            continue
        fi
        
        # Confirm password
        echo -e "\n${BOLD}Confirm password:${NC}"
        read -rs pass_confirm
        echo
        
        if [[ "$pass" != "$pass_confirm" ]]; then
            print_error "Passwords do not match"
            continue
        fi
        
        break
    done
    
    # Test the connection
    if test_api_connection "$prism" "$user" "$pass"; then
        save_credentials "$prism" "$user" "$pass"
        return 0
    else
        echo -e "\n${YELLOW}${WARNING} API connection test failed. Would you like to save the credentials anyway? (y/N)${NC}"
        read -r choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            save_credentials "$prism" "$user" "$pass"
            return 0
        else
            return 1
        fi
    fi
}

# Save credentials securely
save_credentials() {
    local prism=$1
    local user=$2
    local pass=$3
    
    print_loading "Saving credentials..."
    
    # Backup existing credentials if they exist
    if [[ -f "$CREDS_FILE" ]]; then
        cp "$CREDS_FILE" "${CREDS_FILE}${BACKUP_SUFFIX}"
        print_info "Existing credentials backed up to ${CREDS_FILE}${BACKUP_SUFFIX}"
    fi
    
    # Create new credentials file
    cat > "$CREDS_FILE" << EOF
#!/usr/bin/env bash
# Nutanix Prism Central credentials
# Generated by setup_wizard.sh on $(date)
# DO NOT commit this file to version control!

export PRISM="$prism"
export USER="$user"
export PASS="$pass"
EOF
    
    # Set restrictive permissions
    chmod 600 "$CREDS_FILE"
    
    print_success "Credentials saved to $CREDS_FILE"
    print_info "File permissions set to 600 (owner read/write only)"
}

# Display setup summary
display_summary() {
    print_section "Setup Summary"
    
    if [[ -f "$CREDS_FILE" ]]; then
        # Source credentials to display summary
        source "$CREDS_FILE"
        
        echo -e "${BOLD}Configuration:${NC}"
        echo -e "  • Prism Central: ${GREEN}$PRISM${NC}"
        echo -e "  • Username: ${GREEN}$USER${NC}"
        echo -e "  • Credentials file: ${GREEN}$CREDS_FILE${NC}"
        echo -e "  • File permissions: ${GREEN}$(stat -c %a "$CREDS_FILE" 2>/dev/null || stat -f %A "$CREDS_FILE" 2>/dev/null || echo "600")${NC}"
        
        echo -e "\n${BOLD}Available Scripts:${NC}"
        local scripts=(
            "vm_export_menu.sh:Export VMs to OVA backups"
            "vm_restore_menu.sh:Restore VMs from backup points (bulk)"
            "vm_custom_restore.sh:Custom VM restoration with advanced options"
            "manage_restore_points.sh:Manage backup restore points"
        )
        
        for script_info in "${scripts[@]}"; do
            IFS=':' read -r script desc <<< "$script_info"
            if [[ -f "$script" ]]; then
                echo -e "  • ${GREEN}$script${NC} - $desc"
            else
                echo -e "  • ${YELLOW}$script${NC} - $desc (not found)"
            fi
        done
        
        echo -e "\n${BOLD}Next Steps:${NC}"
        echo -e "  1. Run: ${CYAN}chmod +x *.sh${NC}"
        echo -e "  2. Start with: ${CYAN}./vm_export_menu.sh${NC}"
        echo -e "  3. Read the documentation in ${CYAN}CLAUDE.md${NC}"
        
        echo -e "\n${BOLD}Security Notes:${NC}"
        echo -e "  • Credentials are stored in ${YELLOW}$CREDS_FILE${NC}"
        echo -e "  • File has restrictive permissions (600)"
        echo -e "  • ${RED}NEVER${NC} commit this file to version control"
        echo -e "  • Add ${YELLOW}$CREDS_FILE${NC} to your ${YELLOW}.gitignore${NC}"
    else
        print_error "Credentials file not found. Setup may have failed."
    fi
}

# Main menu
main_menu() {
    while true; do
        print_header
        echo -e "${BOLD}Setup Options:${NC}"
        echo -e "  ${CYAN}1.${NC} Check Prerequisites"
        echo -e "  ${CYAN}2.${NC} Configure Credentials"
        echo -e "  ${CYAN}3.${NC} Test API Connection"
        echo -e "  ${CYAN}4.${NC} View Current Configuration"
        echo -e "  ${CYAN}5.${NC} Reset Configuration"
        echo -e "  ${CYAN}6.${NC} Exit"
        
        echo -e "\n${BOLD}Enter your choice (1-6):${NC} "
        read -r choice
        
        case $choice in
            1)
                if check_prerequisites; then
                    print_success "All prerequisites met!"
                    read -p "Press Enter to continue..."
                fi
                ;;
            2)
                if check_prerequisites; then
                    collect_credentials
                    read -p "Press Enter to continue..."
                else
                    print_error "Please install missing prerequisites first"
                    read -p "Press Enter to continue..."
                fi
                ;;
            3)
                if [[ -f "$CREDS_FILE" ]]; then
                    source "$CREDS_FILE"
                    test_api_connection "$PRISM" "$USER" "$PASS"
                else
                    print_error "No credentials configured. Please run option 2 first."
                fi
                read -p "Press Enter to continue..."
                ;;
            4)
                display_summary
                read -p "Press Enter to continue..."
                ;;
            5)
                echo -e "\n${YELLOW}${WARNING} This will remove your current configuration.${NC}"
                echo -e "${BOLD}Are you sure? Type 'RESET' to confirm:${NC} "
                read -r confirm
                if [[ "$confirm" == "RESET" ]]; then
                    if [[ -f "$CREDS_FILE" ]]; then
                        rm "$CREDS_FILE"
                        print_success "Configuration reset"
                    else
                        print_info "No configuration to reset"
                    fi
                else
                    print_info "Reset cancelled"
                fi
                read -p "Press Enter to continue..."
                ;;
            6)
                echo -e "\n${GREEN}${SUCCESS} Setup wizard completed!${NC}"
                if [[ -f "$CREDS_FILE" ]]; then
                    echo -e "${BOLD}You can now run the backup/restore scripts.${NC}"
                else
                    echo -e "${YELLOW}${WARNING} No credentials configured. Run the wizard again to complete setup.${NC}"
                fi
                exit 0
                ;;
            *)
                print_error "Invalid choice. Please enter 1-6."
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

# Quick setup mode (non-interactive)
quick_setup() {
    print_header
    echo -e "${BOLD}Running quick setup...${NC}\n"
    
    if ! check_prerequisites; then
        exit 1
    fi
    
    if collect_credentials; then
        display_summary
        print_success "Quick setup completed successfully!"
    else
        print_error "Quick setup failed"
        exit 1
    fi
}

# Main execution
main() {
    # Check for quick setup flag
    if [[ "${1:-}" == "--quick" ]]; then
        quick_setup
        exit 0
    fi
    
    # Check if already configured
    if [[ -f "$CREDS_FILE" ]]; then
        print_header
        print_info "Existing configuration found"
        echo -e "\n${BOLD}Would you like to:${NC}"
        echo -e "  ${CYAN}1.${NC} Keep existing configuration and exit"
        echo -e "  ${CYAN}2.${NC} Reconfigure credentials"
        echo -e "  ${CYAN}3.${NC} Open setup menu"
        
        echo -e "\n${BOLD}Enter your choice (1-3):${NC} "
        read -r choice
        
        case $choice in
            1)
                display_summary
                exit 0
                ;;
            2)
                collect_credentials
                display_summary
                exit 0
                ;;
            3)
                main_menu
                ;;
            *)
                print_error "Invalid choice"
                exit 1
                ;;
        esac
    else
        main_menu
    fi
}

# Run main function
main "$@"