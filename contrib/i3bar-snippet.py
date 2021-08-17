#!/usr/bin/python3

# This script queries the Travelynx API if you are checked into a train. If
# yes, marudor.de is additionally queried for the next stop, and a JSON object
# like this is written to stdout:
# {"full_text": "RE26824, next: D\u00fcren at <span fgcolor=\"#ff0000\">15:38+5</span>, dest: Aachen Hbf at <span fgcolor=\"#ff0000\">16:07+5</span>", "markup": "pango"},
# The script then exits.
#
# Configuration:
# - Place your API key from https://travelynx.de/account at
#   ~/.config/travelynx.conf .
# - Then integrate into whatever generates your i3bar input.
# - Make sure you use i3bar with a  pango font, so that the color tags are
#   picked up.


from datetime import datetime
import dateutil
import dateutil.parser
import json
from pathlib import Path
import requests
import sys
import xdg  # not pyxdg!


def format_stop(stop_name, scheduled_arrival_timestamp, delay):
    color = "#ffffff"
    if delay > 0:
        if delay <= 2:
            color = "#ffff00"
        else:
            color = "#ff0000"
        delayStr = "{:+.0f}".format(delay)
    else:
        delayStr = ""
    if isinstance(scheduled_arrival_timestamp, int):
        scheduled_arrival_time = datetime.fromtimestamp(scheduled_arrival_timestamp)
    else:
        # We assume it's datetime already.
        scheduled_arrival_time = scheduled_arrival_timestamp
    return f'{stop_name} at <span fgcolor="{color}">{scheduled_arrival_time:%H:%M}{delayStr}</span>'


api_key_path = Path(xdg.xdg_config_home(), "travelynx.conf")
if api_key_path.exists():
    with api_key_path.open("r") as f:
        api_key = f.read().strip()
else:
    print(
        f"Could not find Travelyxn API key at {api_key_path}.",
        file=sys.stderr,
    )
    sys.exit(1)


api_base = f"https://travelynx.de/api/v1/status/{api_key}"
try:
    res = requests.get(api_base)
except requests.exceptions.ConnectionError:
    print(
        json.dumps({"full_text": "Could not connect to travelynx", "color": "#ff0000"})
        + ","
    )
    sys.exit()

j = res.json()
# print(json.dumps(j, sort_keys=True, indent=4), file=sys.stderr)

if not j["checkedIn"]:
    sys.exit()

out_fields = []

train = "{}{}".format(j["train"]["type"], j["train"]["no"])
out_fields.append(train)
destination_name = j["toStation"]["name"]
scheduled_arrival_timestamp = j["toStation"]["scheduledTime"]
delay = (j["toStation"]["realTime"] - j["toStation"]["scheduledTime"]) / 60

try:
    details_res = requests.get(f"https://marudor.de/api/hafas/v2/details/{train}")
    details = details_res.json()
    # print(json.dumps(details, sort_keys=True, indent=4), file=sys.stderr)
    next_stop_name = details["currentStop"]["station"]["title"]
    if next_stop_name == destination_name:
        out_fields.append("next")
    else:
        next_scheduled_arrival_time = dateutil.parser.isoparse(
            details["currentStop"]["arrival"]["scheduledTime"]
        )
        next_scheduled_arrival_time = next_scheduled_arrival_time.astimezone(
            dateutil.tz.tzlocal()
        )
        next_delay = details["currentStop"]["arrival"]["delay"]
        out_fields.append(
            "next: "
            + format_stop(next_stop_name, next_scheduled_arrival_time, next_delay)
        )
except requests.exceptions.ConnectionError:
    pass

out_fields.append(
    "dest: " + format_stop(destination_name, scheduled_arrival_timestamp, delay)
)

s = ", ".join(out_fields)

out_obj = {"full_text": s, "markup": "pango"}
print(json.dumps(out_obj) + ",")
