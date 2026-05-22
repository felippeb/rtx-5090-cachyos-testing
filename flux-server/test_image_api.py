import requests
import base64
import os

image_path = os.path.expanduser("~/Downloads/20250501_193204.jpg")
url = "http://localhost:10500/completion"

try:
    with open(image_path, "rb") as image_file:
        image_base64 = base64.b64encode(image_file.read()).decode('utf-8')

    payload = {
        "prompt": "Describe this image",
        "image_data": image_base64
    }

    print(f"Sending request to {url}...")
    response = requests.post(url, json=payload)
    
    if response.status_code == 200:
        print("Response received:")
        print(response.json())
    else:
        print(f"Error: Status Code {response.status_code}")
        print(response.text)

except Exception as e:
    print(f"An error occurred: {e}")
