import requests
import json
import os
from dotenv import load_dotenv

load_dotenv()

TAIGA_BASE_URL = os.getenv("TAIGA_BASE_URL")
TAIGA_PROJECT_ID = os.getenv("TAIGA_PROJECT_ID")
TAIGA_USERNAME = os.getenv("TAIGA_USERNAME")
TAIGA_PASSWORD = os.getenv("TAIGA_PASSWORD")

def get_token():
    url = f"{TAIGA_BASE_URL}/api/v1/auth"
    payload = {
        "type": "normal",
        "username": TAIGA_USERNAME,
        "password": TAIGA_PASSWORD
    }
    resp = requests.post(url, json=payload)
    resp.raise_for_status()
    return resp.json()["auth_token"]

def fetch_tasks(token):
    url = f"{TAIGA_BASE_URL}/api/v1/tasks?project={TAIGA_PROJECT_ID}&status__is_closed=false"
    headers = {"Authorization": f"Bearer {token}"}
    resp = requests.get(url, headers=headers)
    resp.raise_for_status()
    return resp.json()

if __name__ == "__main__":
    try:
        token = get_token()
        tasks = fetch_tasks(token)
        from datetime import datetime
        today = datetime.now().strftime("%Y-%m-%d")
        
        print(f"Today: {today}")
        print("-" * 50)
        
        overdue_count = 0
        for task in tasks:
            due_date = task.get("due_date")
            if due_date and due_date < today:
                overdue_count += 1
                ref = task.get("ref")
                subject = task.get("subject")
                assignee_info = task.get("assigned_to_extra_info") or {}
                full_name = assignee_info.get("full_name_display", "Unassigned")
                username = assignee_info.get("username", "N/A")
                email = assignee_info.get("email", "N/A")
                
                print(f"Task #{ref}: {subject}")
                print(f"  Due: {due_date}")
                print(f"  Assignee: {full_name} ({username} / {email})")
                print("-" * 30)
        
        print(f"Total overdue tasks: {overdue_count}")
        
    except Exception as e:
        print(f"Error: {e}")
