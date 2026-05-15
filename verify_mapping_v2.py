import json
import re

def load_env_map(env_path):
    with open(env_path, 'r', encoding='utf-8') as f:
        content = f.read()
        match = re.search(r'DISCORD_USER_MAP_JSON=(.*)', content)
        if match:
            return json.loads(match.group(1))
    return {}

USER_MAP = load_env_map('.env')

taiga_users = [
    {"full_name": "cristian andres calambas santa", "username": "crisDev"},
    {"full_name": "Alejandro Vásquez", "username": "Javam26"},
    {"full_name": "mateo herrera salazar", "username": "Mateohs"},
    {"full_name": "Carlos Guillermo Henao Velasqez", "username": "carlosHV"},
    {"full_name": "Anderson Rincón", "username": "Anderson_RS"},
    {"full_name": "julian vasquez", "username": "julianvm"},
    {"full_name": "Anghello Zapata", "username": "Anghello"}
]

def lookup(email, username):
    if email:
        email_lc = email.lower().strip()
        if email_lc in USER_MAP:
            return USER_MAP[email_lc]
    
    if username:
        user_lc = username.lower().strip()
        if user_lc in USER_MAP:
            return USER_MAP[user_lc]
        email_sim = f"{user_lc}@sena.edu.co"
        if email_sim in USER_MAP:
            return USER_MAP[email_sim]
            
    return None

if __name__ == "__main__":
    print(f"{'Name':<35} | {'Username':<15} | {'Discord ID':<20} | Status")
    print("-" * 80)
    for user in taiga_users:
        name = user["full_name"]
        uname = user["username"]
        discord_id = lookup(None, uname)
        status = "OK" if discord_id else "MISSING"
        print(f"{name:<35} | {uname:<15} | {str(discord_id):<20} | {status}")
