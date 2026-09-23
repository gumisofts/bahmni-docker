#!/usr/bin/env python3
"""Map radiology orderables to 'PACS Procedure Code' reference terms.

pacs-integration builds the HL7 ORM from a concept mapping in the
'PACS Procedure Code' source; the CIEL dictionary ships without them, so every
radiology order fails with "Missing concept source for order".
Idempotent: concepts that already have a mapping are skipped.

Usage: OPENMRS_URL=https://127.0.0.1:8443/openmrs OPENMRS_USER=admin OPENMRS_PASSWORD=... \
       python3 add_pacs_procedure_codes.py ["Radiology Orders" "All Radiology orders"]
"""
import base64
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request

BASE = os.environ.get("OPENMRS_URL", "https://127.0.0.1:8443/openmrs").rstrip("/") + "/ws/rest/v1"
AUTH = base64.b64encode(f"{os.environ['OPENMRS_USER']}:{os.environ['OPENMRS_PASSWORD']}".encode()).decode()
SOURCE_NAME = "PACS Procedure Code"
SETS = sys.argv[1:] or ["Radiology Orders", "All Radiology orders"]
CTX = ssl._create_unverified_context()  # local Bahmni proxy uses a self-signed cert


def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header("Authorization", "Basic " + AUTH)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "bahmni-config-script/1.0")  # Cloudflare WAF rejects the default Python-urllib UA
    with urllib.request.urlopen(req, context=CTX) as resp:
        return json.loads(resp.read() or b"{}")


def find_one(path, name):
    for r in call("GET", f"{path}?q={urllib.parse.quote(name)}&v=custom:(uuid,display,name)")["results"]:
        if (r.get("display") or r.get("name")) == name:
            return r["uuid"]
    raise SystemExit(f"not found: {name}")


def leaf_members(uuid, seen, visited_sets=None):
    visited_sets = set() if visited_sets is None else visited_sets
    if uuid in visited_sets or uuid in seen:
        return
    c = call("GET", f"/concept/{uuid}?v=custom:(uuid,display,set,setMembers:(uuid))")
    if not c["set"]:
        seen[uuid] = c["display"]
        return
    visited_sets.add(uuid)  # CIEL sets can reference each other cyclically
    for m in c["setMembers"]:
        leaf_members(m["uuid"], seen, visited_sets)


source_uuid = find_one("/conceptsource", SOURCE_NAME)
same_as = find_one("/conceptmaptype", "SAME-AS")

concepts = {}
for s in SETS:
    leaf_members(find_one("/concept", s), concepts)
print(f"{len(concepts)} radiology orderables found")

added = skipped = 0
for uuid, name in concepts.items():
    c = call("GET", f"/concept/{uuid}?v=custom:(mappings:(conceptReferenceTerm:(code,conceptSource:(name))))")
    codes = {m["conceptReferenceTerm"]["conceptSource"]["name"]: m["conceptReferenceTerm"]["code"] for m in c["mappings"]}
    if SOURCE_NAME in codes:
        skipped += 1
        continue
    # DICOM code values are limited to 16 chars; CIEL codes are short and stable.
    code = codes.get("CIEL") or uuid.replace("-", "")[:16]
    existing = [t for t in call("GET", f"/conceptreferenceterm?source={source_uuid}&codeOrName={urllib.parse.quote(code)}&v=custom:(uuid,code)")["results"] if t["code"] == code]
    term = existing[0]["uuid"] if existing else call("POST", "/conceptreferenceterm", {"code": code, "name": name[:255], "conceptSource": source_uuid})["uuid"]
    call("POST", f"/concept/{uuid}/mapping", {"conceptReferenceTerm": term, "conceptMapType": same_as})
    added += 1
    print(f"mapped {name} -> {code}")

print(f"done: {added} added, {skipped} already mapped")
