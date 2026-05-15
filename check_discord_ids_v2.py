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
                return f"Error: {data.get('message', 'Unknown error')}: {data.get('code','?')}"
        return f"Curl Error: {result.stderr}"
    except Exception as e:
        return f"Python Error: {str(e)}"

def load_json_map(env_path):
    with open(env_path, 'r', encoding='utf-8') as f:
        content = f.read()
        match = re.search(r'DISCORD_USER_MAP_JSON=(.*)', content)
        if match:
            return json.loads(match.group(1))
    return {}

def get_token(env_path):
    with open(env_path, 'r', encoding='utf-8') as f:
        content = f.read()
        match = re.search(r'DISCORD_BOT_TOKEN=(.*)', content)
        if match:
            return match.group(1).strip()
    return None

if __name__ == "__main__":
    env_path = '.env'
    token = get_token(env_path)
    user_map = load_json_map(env_path)
    
    if not token or not user_map:
        print("Missing token or map")
        exit(1)
        
    unique_ids = {}
    for k, v in user_map.items():
        if v not in unique_ids:
            unique_ids[v] = []
        unique_ids[v].append(k)
        
    print(f"{'Discord ID':<20} | {'Discord Name':<30} | Taiga Keys")
    print("-" * 100)
    
    for uid in sorted(unique_ids.keys()):
        if not uid or len(uid) < 5: continue
        info = get_discord_user(token, uid)
        keys = ", ".join(unique_ids[uid])
        print(f"{uid:<20} | {info:<30} | {keys}")
