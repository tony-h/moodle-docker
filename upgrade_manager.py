#!/usr/bin/env python3
# Moodle Upgrade Manager for Docker

import os
import sys
import shutil
import urllib.request
import tarfile
import re
from datetime import datetime
import subprocess

# Directories to scan for custom plugins
PLUGIN_TYPES = [
    'mod', 'blocks', 'local', 'theme', 'report', 
    'auth', 'enrol', 'filter', 'repository', 'course/format'
]

LIVE_DIR = '/var/www/html'
TMP_DIR = '/tmp'

def log(msg):
    print(f"[+] {msg}")

def error_exit(msg):
    print(f"[!] ERROR: {msg}")
    sys.exit(1)

def get_current_branch():
    version_file = os.path.join(LIVE_DIR, 'version.php')
    if not os.path.exists(version_file):
        error_exit(f"Cannot find {version_file}. Is Moodle installed?")
    
    with open(version_file, 'r') as f:
        content = f.read()
        match = re.search(r"\$branch\s*=\s*'(\d+)'", content)
        if match:
            return match.group(1)
    error_exit("Could not determine current Moodle branch from version.php")

def download_and_extract_moodle(branch, dest_dir):
    url = f"https://download.moodle.org/download.php/direct/stable{branch}/moodle-latest-{branch}.tgz"
    tar_path = os.path.join(TMP_DIR, f"moodle-{branch}.tgz")
    
    log(f"Downloading Moodle {branch} from {url}...")
    
    # Send a standard browser User-Agent to bypass 403 Forbidden blocks
    req = urllib.request.Request(
        url, 
        headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'}
    )
    
    try:
        with urllib.request.urlopen(req) as response, open(tar_path, 'wb') as out_file:
            shutil.copyfileobj(response, out_file)
    except Exception as e:
        error_exit(f"Failed to download Moodle {branch}: {e}")
        
    log(f"Extracting Moodle {branch}...")
    with tarfile.open(tar_path, "r:gz") as tar:
        tar.extractall(path=TMP_DIR)
        
    # Moodle extracts to a folder named 'moodle'
    extracted_dir = os.path.join(TMP_DIR, 'moodle')
    if os.path.exists(dest_dir):
        shutil.rmtree(dest_dir)
    os.rename(extracted_dir, dest_dir)
    os.remove(tar_path)

def get_subdirs(path):
    if not os.path.exists(path):
        return set()
    return {d for d in os.listdir(path) if os.path.isdir(os.path.join(path, d))}

def main():
    if len(sys.argv) != 2:
        error_exit("Usage: moodle-upgrade <target_branch> (e.g., moodle-upgrade 500)")
        
    target_branch = sys.argv[1]
    current_branch = get_current_branch()
    
    log(f"Starting Upgrade Manager...")
    log(f"Current Branch: {current_branch}")
    log(f"Target Branch:  {target_branch}")
    
    vanilla_old_dir = os.path.join(TMP_DIR, f"vanilla_{current_branch}")
    moodle_new_dir = os.path.join(TMP_DIR, f"moodle_{target_branch}")
    
    # 1. Prepare Environments
    download_and_extract_moodle(current_branch, vanilla_old_dir)
    download_and_extract_moodle(target_branch, moodle_new_dir)
    
    # 2. Diff and Copy Custom Plugins
    log("Scanning for custom plugins...")
    for p_type in PLUGIN_TYPES:
        live_plugin_path = os.path.join(LIVE_DIR, p_type)
        vanilla_plugin_path = os.path.join(vanilla_old_dir, p_type)
        new_plugin_path = os.path.join(moodle_new_dir, p_type)
        
        live_plugins = get_subdirs(live_plugin_path)
        vanilla_plugins = get_subdirs(vanilla_plugin_path)
        
        # The magic: Plugins in live, but NOT in vanilla
        custom_plugins = live_plugins - vanilla_plugins
        
        for plugin in custom_plugins:
            src = os.path.join(live_plugin_path, plugin)
            dst = os.path.join(new_plugin_path, plugin)
            log(f"  -> Found custom plugin: {p_type}/{plugin}. Copying to new build...")
            shutil.copytree(src, dst)
            
    # 3. Copy other essential files
    config_live = os.path.join(LIVE_DIR, 'config.php')
    if os.path.exists(config_live):
        log("Copying config.php...")
        shutil.copy2(config_live, os.path.join(moodle_new_dir, 'config.php'))
        
    # Copy tinyfilemanager if it exists (since it's not a standard plugin folder)
    tiny_live = os.path.join(LIVE_DIR, 'tinyfilemanager')
    if os.path.exists(tiny_live):
        log("Copying tinyfilemanager...")
        shutil.copytree(tiny_live, os.path.join(moodle_new_dir, 'tinyfilemanager'))

# ... (Steps 1, 2, and 3 remain the same) ...

    # 4. Swap the directories (Docker Volume Safe Method)
    log(f"Clearing old core files from {LIVE_DIR}...")
    for item in os.listdir(LIVE_DIR):
        item_path = os.path.join(LIVE_DIR, item)
        if os.path.isdir(item_path):
            shutil.rmtree(item_path)
        else:
            os.remove(item_path)
            
    log("Installing new merged core...")
    for item in os.listdir(moodle_new_dir):
        s = os.path.join(moodle_new_dir, item)
        d = os.path.join(LIVE_DIR, item)
        if os.path.isdir(s):
            shutil.copytree(s, d)
        else:
            shutil.copy2(s, d)
    
    # 5. Fix ownership and permissions
    log("Setting permissions...")
    subprocess.run(["chown", "-R", "www-data:www-data", LIVE_DIR])
    subprocess.run(["chmod", "0640", os.path.join(LIVE_DIR, 'config.php')])
    
    # Cleanup 
    shutil.rmtree(vanilla_old_dir)
    shutil.rmtree(moodle_new_dir)
    
    log("==========================================")
    log("File replacement complete!")
    log("==========================================")

if __name__ == "__main__":
    main()
