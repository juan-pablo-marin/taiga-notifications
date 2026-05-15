import json
import os
import subprocess
import re

def get_discord_user(token, user_id):
    url = f"https://discord.com/api/v10/users/{user_id}"
    cmd = [
        "curl", "-s", "-X", "GET", url,
        "-H", f"Authorization: Bot {token}",
        "-H", "Content-Type: application/json"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            data = json.loads(result.stdout)
            if "username" in data:
                return f"{data['username']} ({data.get('global_name', 'No Global Name')})"
            else:
                return f"Error: {data.get('message', 'Unknown error')}"
        return f"Curl Error: {result.stderr}"
    except Exception as e:
        return f"Python Error: {str(e)}"

def load_env_vars(env_path):
    vars = {}
    with open(env_path, 'r', encoding='utf-8') as f:
        for line in f:
            if '=' in line and not line.startswith('#'):
                k, v = line.strip().split('=', 1)
                vars[k] = v
    return vars

if __name__ == "__main__":
    env = load_env_vars('.env')
    token = env.get('DISCORD_BOT_TOKEN')
    user_map_str = env.get('DISCORD_USER_MAP_JSON')
    
    if not token or not user_map_str:
        print("Missing DISCORD_BOT_TOKEN or DISCORD_USER_MAP_JSON in .env")
        exit(1)
        
    user_map = json.loads(user_map_str)
    
    # Unique IDs only
    unique_ids = {}
    for k, v in user_map.items():
        if v not in unique_ids:
            unique_ids[v] = []
        unique_ids[v].append(k)
        
    print(f"{'Discord ID':<20} | {'Discord User':<30} | Taiga Keys")
    print("-" * 80)
    
    for uid, keys in unique_ids.items():
        user_info = get_discord_user(token, uid)
        print(f"{uid:<20} | {user_info:<30} | {', '.join(keys)}")
