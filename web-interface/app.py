#!/usr/bin/env python3

from flask import Flask, render_template, jsonify, request
import subprocess
import json
import os
import sys

app = Flask(__name__)
app.config['SECRET_KEY'] = 'nutanix-backup-web-interface-2024'

# Configuration
SCRIPT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESTORE_POINTS_DIR = os.path.join(SCRIPT_DIR, 'restore-points')

def run_command(command, capture_output=True):
    """Run shell command and return result"""
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=capture_output,
            text=True,
            cwd=SCRIPT_DIR,
            executable='/bin/bash'  # Use bash explicitly for source command
        )
        return {
            'success': result.returncode == 0,
            'stdout': result.stdout,
            'stderr': result.stderr,
            'returncode': result.returncode
        }
    except Exception as e:
        return {
            'success': False,
            'error': str(e)
        }

def get_vm_list():
    """Get VM list from Nutanix using existing script logic"""
    try:
        # Check if credentials file exists
        creds_file = os.path.join(SCRIPT_DIR, '.nutanix_creds')
        if not os.path.exists(creds_file):
            return {'error': 'Credentials file not found. Please create .nutanix_creds file.'}
        
        # Source credentials and get VM list
        cmd = f"""
        source {creds_file} && \
        curl -s -k -u "$USER:$PASS" \
        -X POST "https://$PRISM/api/nutanix/v3/vms/list" \
        -H 'Content-Type: application/json' \
        -d '{{"length":1000}}'
        """
        
        result = run_command(cmd)
        
        if not result['success']:
            return {'error': f'Failed to fetch VMs: {result["stderr"]}'}
        
        try:
            vms_json = json.loads(result['stdout'])
        except json.JSONDecodeError:
            return {'error': 'Invalid JSON response from Nutanix API'}
        
        # Process VM data similar to the bash script
        vm_list = []
        if 'entities' in vms_json:
            for vm in vms_json['entities']:
                # Filter out internal VMs and ensure required fields exist
                if (vm.get('metadata', {}).get('project_reference', {}).get('name') and 
                    vm.get('metadata', {}).get('project_reference', {}).get('name') != '_internal'):
                    
                    vm_data = {
                        'name': vm.get('status', {}).get('name', 'Unknown'),
                        'uuid': vm.get('metadata', {}).get('uuid', ''),
                        'project': vm.get('metadata', {}).get('project_reference', {}).get('name', 'Unknown'),
                        'power_state': vm.get('status', {}).get('resources', {}).get('power_state', 'UNKNOWN'),
                        'cluster': vm.get('status', {}).get('cluster_reference', {}).get('name', 'Unknown'),
                        'description': vm.get('status', {}).get('description', ''),
                        'memory_mb': vm.get('status', {}).get('resources', {}).get('memory_size_mib', 0),
                        'vcpus': vm.get('status', {}).get('resources', {}).get('num_vcpus_per_socket', 0) * vm.get('status', {}).get('resources', {}).get('num_sockets', 1)
                    }
                    vm_list.append(vm_data)
        
        # Sort by project then by name
        vm_list.sort(key=lambda x: (x['project'], x['name']))
        
        return {'vms': vm_list}
        
    except Exception as e:
        return {'error': f'Exception occurred: {str(e)}'}

def get_restore_points():
    """Get list of available restore points"""
    try:
        restore_points = []
        if os.path.exists(RESTORE_POINTS_DIR):
            for item in sorted(os.listdir(RESTORE_POINTS_DIR), reverse=True):
                item_path = os.path.join(RESTORE_POINTS_DIR, item)
                if item.startswith('vm-export-') and os.path.isdir(item_path):
                    # Get restore point details
                    tasks_file = os.path.join(item_path, 'vm_export_tasks.csv')
                    vm_count = 0
                    total_size = 0
                    
                    if os.path.exists(tasks_file):
                        try:
                            with open(tasks_file, 'r') as f:
                                lines = f.readlines()[1:]  # Skip header
                                vm_count = len(lines)
                        except:
                            pass
                    
                    # Calculate total size
                    try:
                        for root, dirs, files in os.walk(item_path):
                            for file in files:
                                if file.endswith('.ova'):
                                    file_path = os.path.join(root, file)
                                    total_size += os.path.getsize(file_path)
                    except:
                        pass
                    
                    restore_points.append({
                        'name': item,
                        'timestamp': item.replace('vm-export-', ''),
                        'vm_count': vm_count,
                        'size_bytes': total_size,
                        'size_mb': round(total_size / 1024 / 1024, 1)
                    })
        
        return {'restore_points': restore_points}
    except Exception as e:
        return {'error': f'Failed to get restore points: {str(e)}'}

def check_prerequisites():
    """Check if required tools are available"""
    issues = []
    
    # Check for required commands
    commands = ['curl', 'jq']
    for cmd in commands:
        result = run_command(f'command -v {cmd}')
        if not result['success']:
            issues.append(f'Missing required command: {cmd}')
    
    # Check credentials file
    creds_file = os.path.join(SCRIPT_DIR, '.nutanix_creds')
    if not os.path.exists(creds_file):
        issues.append('Missing .nutanix_creds file')
    
    return issues

@app.route('/')
def index():
    """Main dashboard page"""
    return render_template('index.html')

@app.route('/api/status')
def api_status():
    """Get system status and prerequisites"""
    issues = check_prerequisites()
    return jsonify({
        'status': 'ok' if not issues else 'error',
        'issues': issues,
        'script_dir': SCRIPT_DIR,
        'restore_points_dir': RESTORE_POINTS_DIR
    })

@app.route('/api/vms')
def api_vms():
    """Get list of VMs from Nutanix"""
    vm_data = get_vm_list()
    if 'error' in vm_data:
        return jsonify(vm_data), 500
    return jsonify(vm_data)

@app.route('/api/restore-points')
def api_restore_points():
    """Get list of restore points"""
    restore_data = get_restore_points()
    if 'error' in restore_data:
        return jsonify(restore_data), 500
    return jsonify(restore_data)

@app.route('/api/projects')
def api_projects():
    """Get unique list of projects"""
    vm_data = get_vm_list()
    if 'error' in vm_data:
        return jsonify(vm_data), 500
    
    projects = list(set(vm['project'] for vm in vm_data['vms']))
    projects.sort()
    
    return jsonify({'projects': projects})

@app.route('/api/restore-points/<restore_point_name>/contents')
def api_restore_point_contents(restore_point_name):
    """Get contents (VMs) of a specific restore point"""
    try:
        # URL decode the restore point name
        from urllib.parse import unquote
        restore_point_name = unquote(restore_point_name)
        
        # Validate restore point name format
        if not restore_point_name.startswith('vm-export-'):
            return jsonify({'error': 'Invalid restore point name format'}), 400
        
        restore_point_path = os.path.join(RESTORE_POINTS_DIR, restore_point_name)
        
        # Check if restore point exists
        if not os.path.exists(restore_point_path):
            return jsonify({'error': 'Restore point not found'}), 404
        
        # Read CSV file to get VM details
        tasks_file = os.path.join(restore_point_path, 'vm_export_tasks.csv')
        vms = []
        
        if os.path.exists(tasks_file):
            try:
                with open(tasks_file, 'r') as f:
                    lines = f.readlines()
                    if len(lines) > 1:  # Skip header
                        for line in lines[1:]:
                            parts = line.strip().split(',')
                            if len(parts) >= 3:
                                # Actual CSV format: VM_NAME,VM_UUID,PROJECT_NAME,TASK_UUID,OVA_NAME
                                vm_data = {
                                    'vm_name': parts[0],
                                    'vm_uuid': parts[1],
                                    'project': parts[2],
                                    'task_uuid': parts[3] if len(parts) > 3 else '',
                                    'ova_name': parts[4] if len(parts) > 4 else '',
                                    'status': 'Completed',  # Assume completed if in CSV
                                    'export_time': ''  # Not available in this CSV format
                                }
                                
                                # Check if OVA file exists
                                ova_file = os.path.join(restore_point_path, f"{vm_data['vm_uuid']}.ova")
                                vm_data['ova_exists'] = os.path.exists(ova_file)
                                if vm_data['ova_exists']:
                                    try:
                                        vm_data['ova_size_bytes'] = os.path.getsize(ova_file)
                                    except:
                                        vm_data['ova_size_bytes'] = 0
                                else:
                                    vm_data['ova_size_bytes'] = 0
                                
                                vms.append(vm_data)
            except Exception as e:
                return jsonify({'error': f'Failed to read restore point contents: {str(e)}'}), 500
        
        return jsonify({
            'restore_point': restore_point_name,
            'vms': vms,
            'vm_count': len(vms)
        })
        
    except Exception as e:
        return jsonify({'error': f'Failed to get restore point contents: {str(e)}'}), 500

@app.route('/api/restore-points/<restore_point_name>', methods=['DELETE'])
def api_delete_restore_point(restore_point_name):
    """Delete a specific restore point"""
    try:
        # URL decode the restore point name
        from urllib.parse import unquote
        restore_point_name = unquote(restore_point_name)
        
        # Validate restore point name format
        if not restore_point_name.startswith('vm-export-'):
            return jsonify({'error': 'Invalid restore point name format'}), 400
        
        restore_point_path = os.path.join(RESTORE_POINTS_DIR, restore_point_name)
        
        # Check if restore point exists
        if not os.path.exists(restore_point_path):
            return jsonify({'error': 'Restore point not found'}), 404
        
        # Check if it's actually a directory
        if not os.path.isdir(restore_point_path):
            return jsonify({'error': 'Invalid restore point'}), 400
        
        # Get restore point details before deletion
        tasks_file = os.path.join(restore_point_path, 'vm_export_tasks.csv')
        vm_count = 0
        total_size = 0
        
        if os.path.exists(tasks_file):
            try:
                with open(tasks_file, 'r') as f:
                    lines = f.readlines()[1:]  # Skip header
                    vm_count = len(lines)
            except:
                pass
        
        # Calculate total size
        try:
            for root, dirs, files in os.walk(restore_point_path):
                for file in files:
                    file_path = os.path.join(root, file)
                    total_size += os.path.getsize(file_path)
        except:
            pass
        
        # Delete the restore point directory
        import shutil
        shutil.rmtree(restore_point_path)
        
        return jsonify({
            'success': True,
            'message': f'Restore point {restore_point_name} deleted successfully',
            'deleted_vm_count': vm_count,
            'deleted_size_bytes': total_size
        })
        
    except Exception as e:
        return jsonify({'error': f'Failed to delete restore point: {str(e)}'}), 500

@app.route('/api/restore-points/bulk-delete', methods=['POST'])
def api_bulk_delete_restore_points():
    """Delete multiple restore points"""
    try:
        data = request.get_json()
        if not data or 'restore_points' not in data:
            return jsonify({'error': 'No restore points specified'}), 400
        
        restore_points = data['restore_points']
        if not isinstance(restore_points, list):
            return jsonify({'error': 'Invalid restore points format'}), 400
        
        results = []
        total_deleted_size = 0
        total_deleted_vms = 0
        
        for restore_point_name in restore_points:
            try:
                # Validate restore point name format
                if not restore_point_name.startswith('vm-export-'):
                    results.append({
                        'name': restore_point_name,
                        'success': False,
                        'error': 'Invalid restore point name format'
                    })
                    continue
                
                restore_point_path = os.path.join(RESTORE_POINTS_DIR, restore_point_name)
                
                # Check if restore point exists
                if not os.path.exists(restore_point_path):
                    results.append({
                        'name': restore_point_name,
                        'success': False,
                        'error': 'Restore point not found'
                    })
                    continue
                
                # Get restore point details before deletion
                tasks_file = os.path.join(restore_point_path, 'vm_export_tasks.csv')
                vm_count = 0
                total_size = 0
                
                if os.path.exists(tasks_file):
                    try:
                        with open(tasks_file, 'r') as f:
                            lines = f.readlines()[1:]  # Skip header
                            vm_count = len(lines)
                    except:
                        pass
                
                # Calculate total size
                try:
                    for root, dirs, files in os.walk(restore_point_path):
                        for file in files:
                            file_path = os.path.join(root, file)
                            total_size += os.path.getsize(file_path)
                except:
                    pass
                
                # Delete the restore point directory
                import shutil
                shutil.rmtree(restore_point_path)
                
                results.append({
                    'name': restore_point_name,
                    'success': True,
                    'deleted_vm_count': vm_count,
                    'deleted_size_bytes': total_size
                })
                
                total_deleted_size += total_size
                total_deleted_vms += vm_count
                
            except Exception as e:
                results.append({
                    'name': restore_point_name,
                    'success': False,
                    'error': str(e)
                })
        
        successful_deletes = sum(1 for r in results if r['success'])
        failed_deletes = len(results) - successful_deletes
        
        return jsonify({
            'success': True,
            'results': results,
            'summary': {
                'total_requested': len(restore_points),
                'successful_deletes': successful_deletes,
                'failed_deletes': failed_deletes,
                'total_deleted_size_bytes': total_deleted_size,
                'total_deleted_vms': total_deleted_vms
            }
        })
        
    except Exception as e:
        return jsonify({'error': f'Failed to bulk delete restore points: {str(e)}'}), 500

@app.route('/favicon.ico')
def favicon():
    """Simple favicon handler"""
    return '', 204  # No content

@app.errorhandler(404)
def not_found(error):
    return jsonify({'error': 'Not found'}), 404

@app.errorhandler(500)
def internal_error(error):
    return jsonify({'error': 'Internal server error'}), 500

if __name__ == '__main__':
    print("🚀 Starting Nutanix Web Interface...")
    print(f"📁 Script directory: {SCRIPT_DIR}")
    print(f"📁 Restore points: {RESTORE_POINTS_DIR}")
    
    # Check prerequisites
    issues = check_prerequisites()
    if issues:
        print("\n⚠️  Prerequisites check failed:")
        for issue in issues:
            print(f"   - {issue}")
        print("\nThe web interface will start but may not function properly.")
        print("Please resolve these issues for full functionality.\n")
    else:
        print("✅ Prerequisites check passed")
    
    print(f"🌐 Web interface will be available at: http://localhost:5000")
    print("   Press Ctrl+C to stop the server\n")
    
    # Run Flask development server
    app.run(host='0.0.0.0', port=5000, debug=True, use_reloader=False)