#!/usr/bin/env python3
"""v2 session export JSON -> v1 (1.18.32) import JSON converter.

Invoked by tools/v1-session-port.sh. Reads $SANDBOX/_skeleton.json (a v1-native
export) plus $SANDBOX/exports/*.json (v2 exports), writes $SANDBOX/converted/*.json.

Field mapping (empirically derived — see evidence task-24-sessions.txt):
  v2 message  {id,time,type,text|content,model:{id,providerID},finish,error}
  v1 message  {info:{role,parentID,mode,agent,path,cost,tokens,
                     modelID,providerID,time,finish,error,id,sessionID},
               parts:[{type,text,time,id,sessionID,messageID}]}

v1 hard requirements discovered by probing its zod validator:
  info: slug, title, version
  assistant info: parentID (string, NOT null), modelID, providerID (top-level,
                  not nested in a model object)
  assistant error: {name: <one of 8 named errors>, data:{providerID, modelID, ...}}
"""
import glob
import json
import os
import sys

SB = sys.argv[1] if len(sys.argv) > 1 else "."
OUT = os.path.join(SB, "converted")
os.makedirs(OUT, exist_ok=True)

skel = json.load(open(os.path.join(SB, "_skeleton.json")))
users = [m for m in skel["messages"] if m["info"].get("role") == "user"]
asst = [m for m in skel["messages"] if m["info"].get("role") == "assistant"]
if not users:
    sys.exit("skeleton lacks a user message to use as template")
U_TPL = users[0]
A_TPL = asst[0] if asst else None

# v2 error type -> v1 named-error discriminator
ERR_MAP = {
    "provider.auth": "ProviderAuthError",
    "provider.error": "APIError",
    "api.error": "APIError",
    "message_output_length": "MessageOutputLengthError",
    "message_aborted": "MessageAbortedError",
    "structured_output": "StructuredOutputError",
    "context_overflow": "ContextOverflowError",
    "content_filter": "ContentFilterError",
}
DEFAULT_ERR = "APIError"


def clone(tpl):
    return json.loads(json.dumps(tpl))


def map_error(e):
    """v2 {type,message,status} -> v1 {name, data:{providerID, modelID, message}}."""
    if not isinstance(e, dict):
        return None
    etype = e.get("type") or e.get("name") or ""
    return {
        "name": ERR_MAP.get(etype, DEFAULT_ERR),
        "data": {
            "message": e.get("message", ""),
            "providerID": e.get("providerID", "opencode"),
            "modelID": e.get("modelID", e.get("model", {}).get("id", "unknown")
                           if isinstance(e.get("model"), dict) else "unknown"),
            "status": e.get("status"),
        },
    }


def build(src):
    info = src.get("info", {})
    sid = info.get("id")
    if not sid:
        return None, "no session id"

    out_info = clone(skel["info"])
    loc = info.get("location") or {}
    out_info["id"] = sid
    out_info["slug"] = "v2imp-" + sid[-8:]
    out_info["title"] = info.get("title") or ("v2 imported " + sid[-8:])
    out_info["directory"] = loc.get("directory") or out_info.get("directory", "")
    t = info.get("time") or {}
    out_info["time"] = {"created": t.get("created", 0), "updated": t.get("updated", 0)}

    msgs = []
    last_user = None
    for m in src.get("messages", []):
        mt = m.get("type")
        mt_time = m.get("time") or {}
        if mt == "user":
            n = clone(U_TPL)
            n["info"]["id"] = m["id"]
            n["info"]["sessionID"] = sid
            n["info"]["time"] = {"created": mt_time.get("created", 0)}
            for p in n["parts"]:
                p["id"] = "prt_" + m["id"][4:20]
                p["sessionID"] = sid
                p["messageID"] = m["id"]
                if p.get("type") == "text":
                    p["text"] = m.get("text", "")
            msgs.append(n)
            last_user = m["id"]

        elif mt == "assistant":
            if A_TPL is None:
                continue
            n = clone(A_TPL)
            n["info"]["id"] = m["id"]
            n["info"]["sessionID"] = sid
            n["info"]["parentID"] = last_user or m["id"]
            n["info"]["time"] = {"created": mt_time.get("created", 0)}
            if mt_time.get("completed"):
                n["info"]["time"]["completed"] = mt_time["completed"]
            agent = m.get("agent") or "build"
            n["info"]["agent"] = agent
            n["info"]["mode"] = agent
            mm = m.get("model") or {}
            n["info"]["modelID"] = mm.get("id", "big-pickle")
            n["info"]["providerID"] = mm.get("providerID", "opencode")
            n["info"]["finish"] = m.get("finish") or "stop"
            mapped = map_error(m.get("error"))
            if mapped:
                n["info"]["error"] = mapped
            else:
                n["info"].pop("error", None)

            # text: prefer v2 flat text, then content[] text parts
            txt = m.get("text") or ""
            if not txt:
                buf = []
                for c in m.get("content") or []:
                    if isinstance(c, dict) and c.get("type") == "text":
                        buf.append(c.get("text", ""))
                txt = "\n".join(buf)
            if not txt:
                # NOT directly mappable: tool calls / reasoning / files collapse
                # into one descriptive text part. Listed in the report.
                bits = []
                if m.get("error"):
                    bits.append("error=%s" % json.dumps(m.get("error"))[:200])
                if m.get("content"):
                    kinds = sorted({c.get("type") for c in m["content"]
                                    if isinstance(c, dict)})
                    bits.append("content_types=%s" % kinds)
                if m.get("snapshot"):
                    bits.append("snapshot dropped")
                txt = "[v2 turn: finish=%s %s]" % (m.get("finish"), " ".join(bits))

            # keep only a text part in parts[]
            keep = [p for p in n["parts"] if p.get("type") == "text"]
            p0 = clone(keep[0]) if keep else {
                "type": "text", "text": "", "id": "prt_x",
                "sessionID": sid, "messageID": m["id"]}
            p0["id"] = "prt_" + m["id"][4:20] + "t"
            p0["sessionID"] = sid
            p0["messageID"] = m["id"]
            p0["text"] = txt
            p0["time"] = {"start": mt_time.get("created", 0),
                          "end": mt_time.get("completed", mt_time.get("created", 0))}
            n["parts"] = [p0]
            msgs.append(n)
        # other types (idle / etc.) have no v1 equivalent — dropped

    return {"info": out_info, "messages": msgs}, None


def main():
    ok = fail = 0
    for f in sorted(glob.glob(os.path.join(SB, "exports", "*.json"))):
        try:
            src = json.load(open(f))
        except Exception as exc:  # noqa: BLE001
            print("  SKIP %s: %s" % (os.path.basename(f), exc))
            fail += 1
            continue
        doc, err = build(src)
        if err:
            print("  SKIP %s: %s" % (os.path.basename(f), err))
            fail += 1
            continue
        dst = os.path.join(OUT, doc["info"]["id"] + ".json")
        json.dump(doc, open(dst, "w"), indent=1)
        print("  OK %s -> %s (%d messages)" % (
            os.path.basename(f), os.path.basename(dst), len(doc["messages"])))
        ok += 1
    print("converted %d ok, %d skipped" % (ok, fail))


if __name__ == "__main__":
    main()
