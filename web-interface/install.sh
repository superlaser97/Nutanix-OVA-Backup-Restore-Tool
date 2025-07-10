#!/bin/bash

##############################################################
# install.sh
# ----------------------------------------------------------
# Installation script for Nutanix Web Interface
# Installs Python dependencies and sets up the web server
##############################################################

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}🚀 Installing Nutanix Web Interface...${NC}"
echo ""

# Function to print colored output
print_step() {
    echo -e "${BLUE}➡️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    print_warning "Running as root. Consider running as a regular user for better security."
fi

# Check operating system
print_step "Checking operating system..."
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    print_success "Linux detected"
    OS="linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    print_success "macOS detected"
    OS="mac"
else
    print_error "Unsupported operating system: $OSTYPE"
    exit 1
fi

# Check Python installation
print_step "Checking Python installation..."
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version | cut -d' ' -f2)
    print_success "Python3 found: $PYTHON_VERSION"
    PYTHON_CMD="python3"
elif command -v python &> /dev/null; then
    PYTHON_VERSION=$(python --version 2>&1 | cut -d' ' -f2)
    if [[ $PYTHON_VERSION == 3.* ]]; then
        print_success "Python found: $PYTHON_VERSION"
        PYTHON_CMD="python"
    else
        print_error "Python 3 is required, but found Python $PYTHON_VERSION"
        exit 1
    fi
else
    print_error "Python 3 is not installed"
    echo ""
    echo "Please install Python 3:"
    if [[ "$OS" == "linux" ]]; then
        echo "  Ubuntu/Debian: sudo apt-get install python3 python3-pip"
        echo "  CentOS/RHEL:   sudo yum install python3 python3-pip"
    elif [[ "$OS" == "mac" ]]; then
        echo "  macOS: brew install python3"
    fi
    exit 1
fi

# Check pip installation
print_step "Checking pip installation..."
if command -v pip3 &> /dev/null; then
    print_success "pip3 found"
    PIP_CMD="pip3"
elif command -v pip &> /dev/null; then
    print_success "pip found"
    PIP_CMD="pip"
else
    print_error "pip is not installed"
    echo ""
    echo "Please install pip:"
    if [[ "$OS" == "linux" ]]; then
        echo "  Ubuntu/Debian: sudo apt-get install python3-pip"
        echo "  CentOS/RHEL:   sudo yum install python3-pip"
    elif [[ "$OS" == "mac" ]]; then
        echo "  macOS: python3 -m ensurepip --upgrade"
    fi
    exit 1
fi

# Create requirements.txt
print_step "Creating requirements.txt..."
cat > "$SCRIPT_DIR/requirements.txt" << 'EOF'
Flask==2.3.3
Werkzeug==2.3.7
Jinja2==3.1.2
MarkupSafe==2.1.3
itsdangerous==2.1.2
click==8.1.7
blinker==1.6.3
EOF
print_success "Requirements file created"

# Install Python dependencies
print_step "Installing Python dependencies..."
echo ""

# Try to install in user directory first
if $PIP_CMD install --user -r "$SCRIPT_DIR/requirements.txt"; then
    print_success "Dependencies installed successfully (user install)"
    PIP_INSTALL_TYPE="user"
else
    print_warning "User install failed, trying system install..."
    if sudo $PIP_CMD install -r "$SCRIPT_DIR/requirements.txt"; then
        print_success "Dependencies installed successfully (system install)"
        PIP_INSTALL_TYPE="system"
    else
        print_error "Failed to install Python dependencies"
        exit 1
    fi
fi

# Check if Flask was installed correctly
print_step "Verifying Flask installation..."
if $PYTHON_CMD -c "import flask; print('Flask version:', flask.__version__)" 2>/dev/null; then
    print_success "Flask is working correctly"
else
    print_error "Flask installation verification failed"
    exit 1
fi

# Check prerequisites for the main scripts
print_step "Checking prerequisites for Nutanix scripts..."

# Check curl
if command -v curl &> /dev/null; then
    print_success "curl found"
else
    print_warning "curl not found - required for Nutanix API calls"
    echo "  Install curl:"
    if [[ "$OS" == "linux" ]]; then
        echo "    Ubuntu/Debian: sudo apt-get install curl"
        echo "    CentOS/RHEL:   sudo yum install curl"
    elif [[ "$OS" == "mac" ]]; then
        echo "    macOS: brew install curl"
    fi
fi

# Check jq
if command -v jq &> /dev/null; then
    print_success "jq found"
else
    print_warning "jq not found - required for JSON processing"
    echo "  Install jq:"
    if [[ "$OS" == "linux" ]]; then
        echo "    Ubuntu/Debian: sudo apt-get install jq"
        echo "    CentOS/RHEL:   sudo yum install jq"
    elif [[ "$OS" == "mac" ]]; then
        echo "    macOS: brew install jq"
    fi
fi

# Check credentials file
print_step "Checking Nutanix credentials..."
CREDS_FILE="$PROJECT_DIR/.nutanix_creds"
if [[ -f "$CREDS_FILE" ]]; then
    print_success "Credentials file found"
else
    print_warning "Credentials file not found"
    echo ""
    echo "  Create $CREDS_FILE with the following content:"
    echo ""
    echo "    export PRISM=\"your-prism-central-ip\""
    echo "    export USER=\"your-username\""
    echo "    export PASS=\"your-password\""
    echo ""
fi

# Create startup script
print_step "Creating startup script..."
cat > "$SCRIPT_DIR/start_web_interface.sh" << EOF
#!/bin/bash

# Nutanix Web Interface Startup Script
# Auto-generated by install.sh

set -eu

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="\$(dirname "\$SCRIPT_DIR")"

echo "🚀 Starting Nutanix Web Interface..."
echo "📁 Project directory: \$PROJECT_DIR"
echo "🌐 Web interface will be available at: http://localhost:5000"
echo ""
echo "Press Ctrl+C to stop the server"
echo ""

cd "\$SCRIPT_DIR"
$PYTHON_CMD app.py
EOF

chmod +x "$SCRIPT_DIR/start_web_interface.sh"
print_success "Startup script created"

# Create systemd service (optional)
if command -v systemctl &> /dev/null && [[ "$OS" == "linux" ]]; then
    print_step "Creating systemd service (optional)..."
    
    read -p "Do you want to create a systemd service for auto-start? (y/N): " create_service
    
    if [[ "$create_service" =~ ^[Yy] ]]; then
        SERVICE_FILE="/etc/systemd/system/nutanix-web.service"
        
        sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Nutanix Web Interface
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$PYTHON_CMD $SCRIPT_DIR/app.py
Restart=always
RestartSec=10
Environment=PATH=/usr/bin:/usr/local/bin:$HOME/.local/bin

[Install]
WantedBy=multi-user.target
EOF
        
        sudo systemctl daemon-reload
        
        print_success "Systemd service created"
        echo ""
        echo "To start the service:"
        echo "  sudo systemctl start nutanix-web"
        echo ""
        echo "To enable auto-start on boot:"
        echo "  sudo systemctl enable nutanix-web"
        echo ""
        echo "To check service status:"
        echo "  sudo systemctl status nutanix-web"
        echo ""
    fi
fi

# Final instructions
echo ""
echo -e "${GREEN}🎉 Installation completed successfully!${NC}"
echo ""
echo -e "${BLUE}📋 Next steps:${NC}"
echo ""

if [[ ! -f "$CREDS_FILE" ]]; then
    echo -e "${YELLOW}1. Create credentials file:${NC}"
    echo "   $CREDS_FILE"
    echo ""
fi

echo -e "${BLUE}2. Start the web interface:${NC}"
echo "   cd $SCRIPT_DIR"
echo "   ./start_web_interface.sh"
echo ""
echo "   OR directly:"
echo "   cd $SCRIPT_DIR"
echo "   $PYTHON_CMD app.py"
echo ""

echo -e "${BLUE}3. Open your browser to:${NC}"
echo "   http://localhost:5000"
echo ""

if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}4. Install missing prerequisites (curl, jq) for full functionality${NC}"
    echo ""
fi

echo -e "${BLUE}📁 Project structure:${NC}"
echo "   $PROJECT_DIR/"
echo "   ├── vm_export_menu.sh"
echo "   ├── vm_restore_menu.sh"
echo "   ├── vm_custom_restore.sh"
echo "   ├── manage_restore_points.sh"
echo "   ├── restore-points/"
echo "   └── web-interface/"
echo "       ├── app.py"
echo "       ├── start_web_interface.sh"
echo "       ├── static/"
echo "       └── templates/"
echo ""

echo -e "${GREEN}🔧 Troubleshooting:${NC}"
echo "   - Check firewall settings if accessing from remote machines"
echo "   - Default port is 5000, change in app.py if needed"
echo "   - Check $SCRIPT_DIR/app.py logs for debugging"
echo ""

print_success "Ready to use!"
EOF