// Global state
let vmsData = [];
let restorePointsData = [];
let selectedVMs = new Set();
let selectedRestorePoints = new Set();
let currentFilters = {
    search: '',
    project: '',
    state: ''
};
let deleteOperation = null;

// Initialize the application
document.addEventListener('DOMContentLoaded', function() {
    console.log('🚀 Nutanix Web Interface initializing...');
    
    // Set initial status
    updateStatus('connection-status', '🟢 Connected', 'text-success');
    
    // Load initial data
    loadInitialData();
    
    // Set up event listeners
    setupEventListeners();
    
    console.log('✅ Web interface ready');
});

// Load initial data
async function loadInitialData() {
    showLoading('Loading system status...');
    
    try {
        // Check system status
        const status = await fetchAPI('/api/status');
        updateSystemInfo(status);
        
        if (status.issues && status.issues.length > 0) {
            updateStatus('server-status', '⚠️ Issues detected', 'text-warning');
            showError('System Issues Detected:\n' + status.issues.join('\n'));
        } else {
            updateStatus('server-status', '🟢 System OK', 'text-success');
        }
        
        // Load dashboard data
        await Promise.all([
            loadVMs(),
            loadRestorePoints()
        ]);
        
        updateDashboard();
        
    } catch (error) {
        console.error('Failed to load initial data:', error);
        updateStatus('server-status', '❌ Connection failed', 'text-error');
        showError('Failed to connect to server: ' + error.message);
    } finally {
        hideLoading();
    }
}

// API helper function
async function fetchAPI(endpoint, options = {}) {
    const response = await fetch(endpoint, {
        headers: {
            'Content-Type': 'application/json',
            ...options.headers
        },
        ...options
    });
    
    if (!response.ok) {
        const errorData = await response.json().catch(() => ({ error: 'Network error' }));
        throw new Error(errorData.error || `HTTP ${response.status}`);
    }
    
    return await response.json();
}

// Load VMs data
async function loadVMs() {
    try {
        console.log('📡 Loading VMs...');
        const data = await fetchAPI('/api/vms');
        vmsData = data.vms || [];
        
        // Populate project filter
        const projects = [...new Set(vmsData.map(vm => vm.project))].sort();
        populateProjectFilter(projects);
        
        // Render VMs
        renderVMs();
        
        console.log(`✅ Loaded ${vmsData.length} VMs`);
    } catch (error) {
        console.error('Failed to load VMs:', error);
        showError('Failed to load VMs: ' + error.message);
    }
}

// Load restore points data
async function loadRestorePoints() {
    try {
        console.log('📡 Loading restore points...');
        const data = await fetchAPI('/api/restore-points');
        restorePointsData = data.restore_points || [];
        
        // Render restore points
        renderRestorePoints();
        
        console.log(`✅ Loaded ${restorePointsData.length} restore points`);
    } catch (error) {
        console.error('Failed to load restore points:', error);
        showError('Failed to load restore points: ' + error.message);
    }
}

// Update dashboard statistics
function updateDashboard() {
    // Update VM count
    document.getElementById('total-vms').textContent = vmsData.length;
    
    // Update restore points count
    document.getElementById('restore-points-count').textContent = restorePointsData.length;
    
    // Calculate total storage
    const totalStorage = restorePointsData.reduce((sum, rp) => sum + (rp.size_bytes || 0), 0);
    document.getElementById('storage-used').textContent = formatBytes(totalStorage);
    
    // Get last backup date
    const lastBackup = restorePointsData.length > 0 ? 
        formatDate(restorePointsData[0].timestamp) : 'None';
    document.getElementById('last-backup').textContent = lastBackup;
}

// Update system information
function updateSystemInfo(status) {
    document.getElementById('script-dir').textContent = status.script_dir || 'Unknown';
    document.getElementById('restore-dir').textContent = status.restore_points_dir || 'Unknown';
    
    const systemStatus = status.issues && status.issues.length > 0 ? 
        `⚠️ ${status.issues.length} issues` : '✅ OK';
    document.getElementById('system-status').textContent = systemStatus;
}

// Populate project filter dropdown
function populateProjectFilter(projects) {
    const select = document.getElementById('project-filter');
    
    // Clear existing options except "All Projects"
    while (select.children.length > 1) {
        select.removeChild(select.lastChild);
    }
    
    // Add project options
    projects.forEach(project => {
        const option = document.createElement('option');
        option.value = project;
        option.textContent = project;
        select.appendChild(option);
    });
}

// Render VMs list
function renderVMs() {
    const container = document.getElementById('vm-list');
    
    // Filter VMs based on current filters
    const filteredVMs = vmsData.filter(vm => {
        const matchesSearch = !currentFilters.search || 
            vm.name.toLowerCase().includes(currentFilters.search.toLowerCase());
        const matchesProject = !currentFilters.project || vm.project === currentFilters.project;
        const matchesState = !currentFilters.state || vm.power_state === currentFilters.state;
        
        return matchesSearch && matchesProject && matchesState;
    });
    
    if (filteredVMs.length === 0) {
        container.innerHTML = '<div class="loading">No VMs found matching current filters</div>';
        return;
    }
    
    // Render VM items
    container.innerHTML = filteredVMs.map(vm => `
        <div class="vm-item">
            <input type="checkbox" 
                   id="vm-${vm.uuid}" 
                   data-vm-uuid="${vm.uuid}"
                   ${selectedVMs.has(vm.uuid) ? 'checked' : ''}>
            <div class="vm-name">${escapeHtml(vm.name)}</div>
            <div class="vm-project">${escapeHtml(vm.project)}</div>
            <div class="power-state ${vm.power_state}">
                ${getPowerStateIcon(vm.power_state)} ${vm.power_state}
            </div>
            <div class="vm-specs">
                ${vm.vcpus || 0} vCPU, ${Math.round((vm.memory_mb || 0) / 1024)}GB RAM
            </div>
            <div class="vm-actions">
                <button onclick="viewVMDetails('${vm.uuid}')" class="btn-secondary" style="padding: 0.25rem 0.5rem; font-size: 0.75rem;">
                    👁️ Details
                </button>
            </div>
        </div>
    `).join('');
    
    // Add event listeners for checkboxes
    container.querySelectorAll('input[type="checkbox"]').forEach(checkbox => {
        checkbox.addEventListener('change', function() {
            const vmUuid = this.dataset.vmUuid;
            if (this.checked) {
                selectedVMs.add(vmUuid);
            } else {
                selectedVMs.delete(vmUuid);
            }
            updateSelectionSummary();
        });
    });
}

// Render restore points list
function renderRestorePoints() {
    const container = document.getElementById('restore-points-list');
    
    if (restorePointsData.length === 0) {
        container.innerHTML = '<div class="loading">No restore points found</div>';
        updateRestorePointsSelection();
        return;
    }
    
    container.innerHTML = restorePointsData.map(rp => `
        <div class="restore-point-item ${selectedRestorePoints.has(rp.name) ? 'selected' : ''}" data-restore-point="${rp.name}">
            <input type="checkbox" 
                   class="restore-point-checkbox" 
                   data-restore-point="${rp.name}"
                   ${selectedRestorePoints.has(rp.name) ? 'checked' : ''}>
            <div class="restore-point-name">📦 ${escapeHtml(rp.name)}</div>
            <div class="restore-point-date">${formatDate(rp.timestamp)}</div>
            <div class="restore-point-vms">${rp.vm_count}</div>
            <div class="restore-point-size">${formatBytes(rp.size_bytes)}</div>
            <div class="restore-point-actions">
                <button onclick="viewRestorePointContents('${rp.name}')" class="btn-secondary" style="padding: 0.25rem 0.5rem; font-size: 0.75rem; margin-right: 0.5rem;">
                    👁️ View VMs
                </button>
                <button onclick="deleteRestorePoint('${rp.name}')" class="delete-btn-small">
                    🗑️ Delete
                </button>
            </div>
        </div>
    `).join('');
    
    // Add event listeners for checkboxes
    container.querySelectorAll('.restore-point-checkbox').forEach(checkbox => {
        checkbox.addEventListener('change', function() {
            const rpName = this.dataset.restorePoint;
            const rpItem = this.closest('.restore-point-item');
            
            if (this.checked) {
                selectedRestorePoints.add(rpName);
                rpItem.classList.add('selected');
            } else {
                selectedRestorePoints.delete(rpName);
                rpItem.classList.remove('selected');
            }
            updateRestorePointsSelection();
        });
    });
}

// Get power state icon
function getPowerStateIcon(state) {
    switch (state) {
        case 'ON': return '🟢';
        case 'OFF': return '🔴';
        default: return '⚪';
    }
}

// Format bytes to human readable
function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
}

// Format date from timestamp
function formatDate(timestamp) {
    if (!timestamp) return 'Unknown';
    
    // Parse timestamp like "2025-07-09_03-11-33"
    const match = timestamp.match(/^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})$/);
    if (!match) return timestamp;
    
    const [, year, month, day, hour, minute, second] = match;
    const date = new Date(year, month - 1, day, hour, minute, second);
    
    return date.toLocaleDateString();
}

// Format timestamp to readable format
function formatTimestamp(timestamp) {
    if (!timestamp) return 'Unknown';
    
    const match = timestamp.match(/^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})$/);
    if (!match) return timestamp;
    
    const [, year, month, day, hour, minute, second] = match;
    const date = new Date(year, month - 1, day, hour, minute, second);
    
    return date.toLocaleString();
}

// Escape HTML to prevent XSS
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Update status indicator
function updateStatus(elementId, text, className = '') {
    const element = document.getElementById(elementId);
    if (element) {
        element.textContent = text;
        element.className = 'status-indicator ' + className;
    }
}

// Update selection summary
function updateSelectionSummary() {
    const count = selectedVMs.size;
    document.getElementById('selected-count').textContent = `${count} VMs selected`;
    document.getElementById('export-selected').disabled = count === 0;
    
    // Update select all checkbox
    const selectAllCheckbox = document.getElementById('select-all-vms');
    if (selectAllCheckbox) {
        const visibleCheckboxes = document.querySelectorAll('#vm-list input[type="checkbox"]');
        const checkedBoxes = document.querySelectorAll('#vm-list input[type="checkbox"]:checked');
        
        selectAllCheckbox.checked = visibleCheckboxes.length > 0 && 
                                   visibleCheckboxes.length === checkedBoxes.length;
        selectAllCheckbox.indeterminate = checkedBoxes.length > 0 && 
                                         checkedBoxes.length < visibleCheckboxes.length;
    }
}

// Setup event listeners
function setupEventListeners() {
    // Search input
    const searchInput = document.getElementById('vm-search');
    if (searchInput) {
        searchInput.addEventListener('input', function() {
            currentFilters.search = this.value;
            renderVMs();
        });
    }
    
    // Project filter
    const projectFilter = document.getElementById('project-filter');
    if (projectFilter) {
        projectFilter.addEventListener('change', function() {
            currentFilters.project = this.value;
            renderVMs();
        });
    }
    
    // State filter
    const stateFilter = document.getElementById('state-filter');
    if (stateFilter) {
        stateFilter.addEventListener('change', function() {
            currentFilters.state = this.value;
            renderVMs();
        });
    }
}

// Tab navigation
function showTab(tabName) {
    // Hide all tab contents
    document.querySelectorAll('.tab-content').forEach(tab => {
        tab.classList.remove('active');
    });
    
    // Remove active class from all tab buttons
    document.querySelectorAll('.tab-button').forEach(button => {
        button.classList.remove('active');
    });
    
    // Show selected tab
    const selectedTab = document.getElementById(tabName);
    if (selectedTab) {
        selectedTab.classList.add('active');
    }
    
    // Add active class to selected button
    const selectedButton = document.getElementById(`tab-${tabName}`);
    if (selectedButton) {
        selectedButton.classList.add('active');
    }
}

// Toggle select all VMs
function toggleSelectAll() {
    const selectAllCheckbox = document.getElementById('select-all-vms');
    const visibleCheckboxes = document.querySelectorAll('#vm-list input[type="checkbox"]');
    
    visibleCheckboxes.forEach(checkbox => {
        const vmUuid = checkbox.dataset.vmUuid;
        checkbox.checked = selectAllCheckbox.checked;
        
        if (selectAllCheckbox.checked) {
            selectedVMs.add(vmUuid);
        } else {
            selectedVMs.delete(vmUuid);
        }
    });
    
    updateSelectionSummary();
}

// Refresh functions
async function refreshData() {
    await loadInitialData();
    showSuccess('Data refreshed successfully');
}

async function refreshVMs() {
    showLoading('Refreshing VMs...');
    try {
        await loadVMs();
        showSuccess('VMs refreshed successfully');
    } finally {
        hideLoading();
    }
}

async function refreshRestorePoints() {
    showLoading('Refreshing restore points...');
    try {
        await loadRestorePoints();
        updateDashboard();
        showSuccess('Restore points refreshed successfully');
    } finally {
        hideLoading();
    }
}

// Export selected VMs (placeholder for Phase 2)
function exportSelected() {
    if (selectedVMs.size === 0) {
        showError('No VMs selected for export');
        return;
    }
    
    const selectedVMsList = Array.from(selectedVMs).map(uuid => {
        const vm = vmsData.find(v => v.uuid === uuid);
        return vm ? vm.name : uuid;
    }).join(', ');
    
    showSuccess(`Export functionality will be implemented in Phase 2.\nSelected VMs: ${selectedVMsList}`);
}

// Global variable to store current VM for export
let currentVMForExport = null;

// View VM details with formatted modal
function viewVMDetails(vmUuid) {
    const vm = vmsData.find(v => v.uuid === vmUuid);
    if (!vm) {
        showError('VM not found');
        return;
    }
    
    // Store current VM for potential export
    currentVMForExport = vm;
    
    // Format memory
    const memoryGB = Math.round((vm.memory_mb || 0) / 1024);
    const memoryDisplay = memoryGB > 0 ? `${memoryGB} GB` : 'Unknown';
    
    // Format vCPUs
    const vcpuDisplay = vm.vcpus && vm.vcpus > 0 ? vm.vcpus.toString() : 'Unknown';
    
    // Create formatted HTML content
    const detailsHTML = `
        <div class="vm-details-grid">
            <div class="vm-detail-section">
                <h4>📋 Basic Information</h4>
                <div class="vm-detail-item">
                    <span class="vm-detail-label">Name:</span>
                    <span class="vm-detail-value">${escapeHtml(vm.name)}</span>
                </div>
                <div class="vm-detail-item">
                    <span class="vm-detail-label">Project:</span>
                    <span class="vm-detail-value">${escapeHtml(vm.project)}</span>
                </div>
                <div class="vm-detail-item">
                    <span class="vm-detail-label">Cluster:</span>
                    <span class="vm-detail-value">${escapeHtml(vm.cluster || 'Unknown')}</span>
                </div>
                <div class="vm-detail-item">
                    <span class="vm-detail-label">Power State:</span>
                    <span class="vm-detail-value">
                        <span class="power-state-badge ${vm.power_state}">
                            ${getPowerStateIcon(vm.power_state)} ${vm.power_state}
                        </span>
                    </span>
                </div>
            </div>
            
            <div class="vm-detail-section">
                <h4>⚙️ Virtual Machine Specs</h4>
                <div class="vm-detail-item">
                    <span class="vm-detail-label">vCPUs:</span>
                    <span class="vm-detail-value">${vcpuDisplay}</span>
                </div>
                <div class="vm-detail-item">
                    <span class="vm-detail-label">Memory:</span>
                    <span class="vm-detail-value">${memoryDisplay}</span>
                </div>
                <div class="vm-detail-item">
                    <span class="vm-detail-label">UUID:</span>
                    <span class="vm-detail-value">
                        <div class="vm-uuid" title="Click to copy" onclick="copyToClipboard('${vm.uuid}')">
                            ${vm.uuid}
                        </div>
                    </span>
                </div>
            </div>
        </div>
        
        ${vm.description && vm.description.trim() ? `
            <div class="vm-detail-section">
                <h4>📝 Description</h4>
                <div class="vm-description-full">${escapeHtml(vm.description)}</div>
            </div>
        ` : ''}
    `;
    
    // Update modal content
    document.getElementById('vm-details-content').innerHTML = detailsHTML;
    
    // Show the modal
    showModal('vm-details-modal');
}

// Export single VM function
function exportSingleVM() {
    if (!currentVMForExport) {
        showError('No VM selected for export');
        return;
    }
    
    // Clear any existing selections and select only this VM
    selectedVMs.clear();
    selectedVMs.add(currentVMForExport.uuid);
    
    // Close the details modal
    closeModal('vm-details-modal');
    
    // Switch to VMs tab and update the selection
    showTab('vms');
    renderVMs();
    updateSelectionSummary();
    
    // Show success message
    showSuccess(`VM "${currentVMForExport.name}" selected for export. Click "Export Selected VMs" to proceed.`);
}

// Copy to clipboard function
function copyToClipboard(text) {
    if (navigator.clipboard) {
        navigator.clipboard.writeText(text).then(() => {
            showSuccess('UUID copied to clipboard!');
        }).catch(() => {
            showError('Failed to copy UUID');
        });
    } else {
        // Fallback for older browsers
        const textArea = document.createElement('textarea');
        textArea.value = text;
        document.body.appendChild(textArea);
        textArea.select();
        try {
            document.execCommand('copy');
            showSuccess('UUID copied to clipboard!');
        } catch (err) {
            showError('Failed to copy UUID');
        }
        document.body.removeChild(textArea);
    }
}

// Manage restore points (placeholder)
function manageRestorePoints() {
    showSuccess('Restore point management will open the existing manage_restore_points.sh script');
}

// Loading overlay
function showLoading(message = 'Loading...') {
    const overlay = document.getElementById('loading-overlay');
    const messageElement = document.getElementById('loading-message');
    
    if (messageElement) {
        messageElement.textContent = message;
    }
    
    if (overlay) {
        overlay.classList.add('show');
    }
}

function hideLoading() {
    const overlay = document.getElementById('loading-overlay');
    if (overlay) {
        overlay.classList.remove('show');
    }
}

// Modal functions
function showModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.classList.add('show');
    }
}

function closeModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.classList.remove('show');
    }
}

function showError(message) {
    document.getElementById('error-message').textContent = message;
    showModal('error-modal');
}

function showSuccess(message) {
    document.getElementById('success-message').textContent = message;
    showModal('success-modal');
}

// Disable closing modals when clicking outside
// Users must use the close button to close modals
document.addEventListener('click', function(event) {
    // Remove this functionality - modals can only be closed with close button
    // if (event.target.classList.contains('modal')) {
    //     event.target.classList.remove('show');
    // }
});

// Keyboard shortcuts
document.addEventListener('keydown', function(event) {
    // Close modals with Escape key
    if (event.key === 'Escape') {
        document.querySelectorAll('.modal.show').forEach(modal => {
            modal.classList.remove('show');
        });
    }
});

// Restore Points Selection Management
function updateRestorePointsSelection() {
    const count = selectedRestorePoints.size;
    const countElement = document.getElementById('selected-restore-points-count');
    const sizeElement = document.getElementById('selected-restore-points-size');
    const bulkDeleteBtn = document.getElementById('bulk-delete-btn');
    const summaryElement = document.getElementById('restore-points-summary');
    
    if (countElement) countElement.textContent = `${count} restore points selected`;
    if (bulkDeleteBtn) bulkDeleteBtn.disabled = count === 0;
    
    // Calculate total size of selected restore points
    let totalSize = 0;
    selectedRestorePoints.forEach(rpName => {
        const rp = restorePointsData.find(r => r.name === rpName);
        if (rp) totalSize += rp.size_bytes;
    });
    
    if (sizeElement) sizeElement.textContent = `${formatBytes(totalSize)} total`;
    if (summaryElement) summaryElement.style.display = count > 0 ? 'flex' : 'none';
    
    // Update select all checkbox
    const selectAllCheckbox = document.getElementById('select-all-restore-points-header');
    if (selectAllCheckbox) {
        selectAllCheckbox.checked = restorePointsData.length > 0 && 
                                   selectedRestorePoints.size === restorePointsData.length;
        selectAllCheckbox.indeterminate = selectedRestorePoints.size > 0 && 
                                         selectedRestorePoints.size < restorePointsData.length;
    }
}

// Toggle select all restore points
function toggleSelectAllRestorePoints() {
    const selectAllCheckbox = document.getElementById('select-all-restore-points-header');
    const checkboxes = document.querySelectorAll('.restore-point-checkbox');
    
    if (selectAllCheckbox.checked) {
        // Select all
        restorePointsData.forEach(rp => selectedRestorePoints.add(rp.name));
    } else {
        // Deselect all
        selectedRestorePoints.clear();
    }
    
    // Update UI
    renderRestorePoints();
    updateRestorePointsSelection();
}

// Delete single restore point
function deleteRestorePoint(restorePointName) {
    const rp = restorePointsData.find(r => r.name === restorePointName);
    if (!rp) {
        showError('Restore point not found');
        return;
    }
    
    deleteOperation = {
        type: 'single',
        restorePoints: [restorePointName]
    };
    
    const content = `
        <div class="delete-summary">
            <h4>Delete Restore Point</h4>
            <p><strong>Name:</strong> ${escapeHtml(rp.name)}</p>
            <p><strong>VMs:</strong> ${rp.vm_count}</p>
            <p><strong>Size:</strong> ${formatBytes(rp.size_bytes)}</p>
            <p><strong>Date:</strong> ${formatTimestamp(rp.timestamp)}</p>
        </div>
    `;
    
    document.getElementById('delete-confirmation-content').innerHTML = content;
    document.getElementById('delete-confirmation-input').value = '';
    document.getElementById('confirm-delete-btn').disabled = true;
    showModal('delete-confirmation-modal');
}

// Bulk delete restore points
function bulkDeleteRestorePoints() {
    if (selectedRestorePoints.size === 0) {
        showError('No restore points selected for deletion');
        return;
    }
    
    deleteOperation = {
        type: 'bulk',
        restorePoints: Array.from(selectedRestorePoints)
    };
    
    const selectedRPs = Array.from(selectedRestorePoints).map(name => 
        restorePointsData.find(rp => rp.name === name)
    ).filter(rp => rp);
    
    const totalSize = selectedRPs.reduce((sum, rp) => sum + rp.size_bytes, 0);
    const totalVMs = selectedRPs.reduce((sum, rp) => sum + rp.vm_count, 0);
    
    const content = `
        <div class="delete-summary">
            <h4>Bulk Delete Restore Points</h4>
            <p><strong>Count:</strong> ${selectedRPs.length} restore points</p>
            <p><strong>Total VMs:</strong> ${totalVMs}</p>
            <p><strong>Total Size:</strong> ${formatBytes(totalSize)}</p>
            <div class="restore-points-list">
                ${selectedRPs.map(rp => `
                    <div class="restore-point-summary">
                        📦 ${escapeHtml(rp.name)} (${rp.vm_count} VMs, ${formatBytes(rp.size_bytes)})
                    </div>
                `).join('')}
            </div>
        </div>
    `;
    
    document.getElementById('delete-confirmation-content').innerHTML = content;
    document.getElementById('delete-confirmation-input').value = '';
    document.getElementById('confirm-delete-btn').disabled = true;
    showModal('delete-confirmation-modal');
}

// Handle delete confirmation input
document.addEventListener('DOMContentLoaded', function() {
    const deleteInput = document.getElementById('delete-confirmation-input');
    const confirmBtn = document.getElementById('confirm-delete-btn');
    
    if (deleteInput && confirmBtn) {
        deleteInput.addEventListener('input', function() {
            confirmBtn.disabled = this.value.trim().toUpperCase() !== 'DELETE';
        });
    }
});

// Confirm delete operation
async function confirmDelete() {
    if (!deleteOperation) {
        showError('No delete operation in progress');
        return;
    }
    
    const input = document.getElementById('delete-confirmation-input');
    if (input.value.trim().toUpperCase() !== 'DELETE') {
        showError('Please type DELETE to confirm');
        return;
    }
    
    closeModal('delete-confirmation-modal');
    showLoading('Deleting restore points...');
    
    try {
        if (deleteOperation.type === 'single') {
            // Single delete
            const restorePointName = deleteOperation.restorePoints[0];
            const response = await fetchAPI(`/api/restore-points/${encodeURIComponent(restorePointName)}`, {
                method: 'DELETE'
            });
            
            if (response.success) {
                showSuccess(`Restore point deleted successfully.\nFreed ${formatBytes(response.deleted_size_bytes)} (${response.deleted_vm_count} VMs)`);
                
                // Remove from selected set
                selectedRestorePoints.delete(restorePointName);
                
                // Refresh data
                await loadRestorePoints();
                updateDashboard();
                updateRestorePointsSelection();
            } else {
                showError(response.message || 'Failed to delete restore point');
            }
        } else {
            // Bulk delete
            const response = await fetchAPI('/api/restore-points/bulk-delete', {
                method: 'POST',
                body: JSON.stringify({
                    restore_points: deleteOperation.restorePoints
                })
            });
            
            if (response.success) {
                const summary = response.summary;
                let message = `Bulk delete completed.\n`;
                message += `Successful: ${summary.successful_deletes}/${summary.total_requested}\n`;
                message += `Failed: ${summary.failed_deletes}\n`;
                message += `Freed: ${formatBytes(summary.total_deleted_size_bytes)} (${summary.total_deleted_vms} VMs)`;
                
                if (summary.failed_deletes > 0) {
                    const failedItems = response.results.filter(r => !r.success);
                    message += `\n\nFailed items:\n${failedItems.map(r => `- ${r.name}: ${r.error}`).join('\n')}`;
                }
                
                showSuccess(message);
                
                // Clear selected restore points
                selectedRestorePoints.clear();
                
                // Refresh data
                await loadRestorePoints();
                updateDashboard();
                updateRestorePointsSelection();
            } else {
                showError(response.message || 'Failed to delete restore points');
            }
        }
    } catch (error) {
        console.error('Delete operation failed:', error);
        showError('Delete operation failed: ' + error.message);
    } finally {
        hideLoading();
        deleteOperation = null;
    }
}

// View restore point contents
async function viewRestorePointContents(restorePointName) {
    try {
        showLoading('Loading restore point contents...');
        
        // Fetch restore point contents
        const encodedName = encodeURIComponent(restorePointName);
        const url = `/api/restore-points/${encodedName}/contents`;
        const response = await fetchAPI(url);
        
        if (!response.vms) {
            showError('Failed to load restore point contents');
            return;
        }
        
        // Update restore point info
        const rp = restorePointsData.find(r => r.name === restorePointName);
        const infoHTML = `
            <div class="restore-point-info">
                <h4>📦 ${escapeHtml(restorePointName)}</h4>
                <div class="restore-point-details">
                    <div class="detail-item">
                        <span><strong>Date Created:</strong> ${formatTimestamp(rp.timestamp)}</span>
                    </div>
                    <div class="detail-item">
                        <span><strong>Total VMs:</strong> ${response.vm_count}</span>
                    </div>
                    <div class="detail-item">
                        <span><strong>Total Size:</strong> ${formatBytes(rp.size_bytes)}</span>
                    </div>
                </div>
            </div>
        `;
        
        document.getElementById('restore-point-info').innerHTML = infoHTML;
        
        // Render VMs in the restore point
        const vmContainer = document.getElementById('restore-point-vm-list');
        
        if (response.vms.length === 0) {
            vmContainer.innerHTML = '<div class="loading">No VMs found in this restore point</div>';
        } else {
            vmContainer.innerHTML = response.vms.map(vm => `
                <div class="vm-item">
                    <div class="vm-name">${escapeHtml(vm.vm_name || 'Unknown')}</div>
                    <div class="vm-project">${escapeHtml(vm.project || 'Unknown')}</div>
                    <div class="vm-uuid" onclick="copyToClipboard('${vm.vm_uuid}')" title="Click to copy UUID" style="cursor: pointer;">
                        ${vm.vm_uuid || 'Unknown'}
                    </div>
                    <div class="vm-size">${formatBytes(vm.ova_size_bytes || 0)}</div>
                    <div class="vm-file-status">
                        ${vm.ova_exists ? 
                            '<span class="file-status-good">✅ Available</span>' : 
                            '<span class="file-status-missing">❌ Missing</span>'
                        }
                    </div>
                </div>
            `).join('');
        }
        
        // Show the modal
        showModal('restore-point-contents-modal');
        
    } catch (error) {
        console.error('Failed to load restore point contents:', error);
        showError('Failed to load restore point contents: ' + error.message);
    } finally {
        hideLoading();
    }
}

// Get export status icon
function getExportStatusIcon(status) {
    switch (status.toLowerCase()) {
        case 'completed':
        case 'success':
            return '✅';
        case 'failed':
        case 'error':
            return '❌';
        case 'in_progress':
        case 'running':
            return '🔄';
        default:
            return '⚪';
    }
}

console.log('📱 Nutanix Web Interface JavaScript loaded');