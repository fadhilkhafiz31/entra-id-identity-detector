import requests
from datetime import datetime
from math import radians, sin, cos, sqrt, atan2

# ---- FILL THESE IN ----
TENANT_ID = "TENANT_ID"
CLIENT_ID = "CLIENT_ID"
CLIENT_SECRET = "CLIENT_SECRET"
# ------------------------

def get_token():
    url = f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token"
    data = {
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "scope": "https://graph.microsoft.com/.default",
        "grant_type": "client_credentials",
    }
    resp = requests.post(url, data=data)
    resp.raise_for_status()
    return resp.json()["access_token"]

def get_signin_logs(token, top=50):
    url = "https://graph.microsoft.com/v1.0/auditLogs/signIns"
    headers = {"Authorization": f"Bearer {token}"}
    params = {"$top": top, "$orderby": "createdDateTime asc"}
    resp = requests.get(url, headers=headers, params=params)
    resp.raise_for_status()
    return resp.json().get("value", [])

def haversine_km(lat1, lon1, lat2, lon2):
    R = 6371.0
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ** 2
    c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return R * c

def detect_impossible_travel(logs, min_distance_km=500, max_speed_kmh=900):
    by_user = {}
    for entry in logs:
        if entry.get("status", {}).get("errorCode") != 0:
            continue  # only successful sign-ins
        upn = entry.get("userPrincipalName")
        # Extract location data
        geo = entry.get("location", {}).get("geoCoordinates", {}) or {}
        loc = geo.get("latitude"), geo.get("longitude")
        if not upn or loc[0] is None or loc[1] is None:
            continue
        time = datetime.fromisoformat(entry["createdDateTime"].replace("Z", "+00:00"))
        by_user.setdefault(upn, []).append((time, loc[0], loc[1], entry.get("location", {}).get("city"), entry.get("location", {}).get("countryOrRegion")))

    flagged = []
    for upn, events in by_user.items():
        events.sort(key=lambda e: e[0])
        for i in range(1, len(events)):
            t1, lat1, lon1, city1, country1 = events[i - 1]
            t2, lat2, lon2, city2, country2 = events[i]
            distance = haversine_km(lat1, lon1, lat2, lon2)
            hours = max((t2 - t1).total_seconds() / 3600, 0.001)
            speed = distance / hours
            if distance > min_distance_km and speed > max_speed_kmh:
                flagged.append({
                    "user": upn,
                    "from": f"{city1}, {country1}", "from_time": t1,
                    "to": f"{city2}, {country2}", "to_time": t2,
                    "distance_km": round(distance), "speed_kmh": round(speed),
                })
    return flagged

if __name__ == "__main__":
    token = get_token()
    logs = get_signin_logs(token, top=100)
    print(f"Pulled {len(logs)} sign-in events")
    results = detect_impossible_travel(logs)
    if not results:
        print("No impossible travel detected.")
    for r in results:
        print(f"\n[IMPOSSIBLE TRAVEL] {r['user']}")
        print(f"  {r['from']} @ {r['from_time']}  ->  {r['to']} @ {r['to_time']}")
        print(f"  Distance: {r['distance_km']} km, Speed: {r['speed_kmh']} km/h")