import json
import os
from dotenv import load_dotenv

load_dotenv()

USER_MAP = json.loads(os.getenv("DISCORD_USER_MAP_JSON", "{}"))

# Simulated Taiga assignees found earlier
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
    # Logic from remind.sh
    if email:
        email_lc = email.lower().strip()
        if email_lc in USER_MAP:
            return USER_MAP[email_lc]
    
    if username:
        user_lc = username.lower().strip()
        # 1. Check username directly
        if user_lc in USER_MAP:
            return USER_MAP[user_lc]
        # 2. Check username@sena.edu.co
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
        discord_id = lookup(None, uname) # email is null in Taiga API
        status = "OK" if discord_id else "MISSING"
        print(f"{name:<35} | {uname:<15} | {str(discord_id):<20} | {status}")
