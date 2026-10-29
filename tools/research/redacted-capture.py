"""mitmproxy addon that records request shapes without sensitive content.

Run: mitmdump --mode local:Mimestream -s redacted-capture.py --set capture_out=/path/out.jsonl

Logged: method, host, path with IDs and email addresses replaced, query parameter
names (values only for an allowlist), status, sizes, timing, inner requests of Google
batch calls, and IMAP command and response names from fixed allowlists. Never logged:
headers other than the client library hint, bodies, tokens, search queries, mailbox
names other than INBOX and [Gmail]/..., or message data.
"""

import json
import re
import time
from urllib.parse import parse_qsl, urlsplit

from mitmproxy import ctx, http, tcp

SAFE_QUERY_VALUES = {
    "format", "maxResults", "fields", "historyTypes", "includeSpamTrash",
    "metadataHeaders", "prettyPrint", "alt", "personFields", "readMask",
    "sources", "uploadType", "internalDateSource", "neverMarkSpam",
    "processForCalendar", "deleted", "showDeleted", "singleEvents", "orderBy",
}
SYSTEM_LABEL = re.compile(r"^(INBOX|SENT|DRAFT|SPAM|TRASH|STARRED|IMPORTANT|UNREAD|CHAT|CATEGORY_[A-Z]+)$")
ID_SEGMENT = re.compile(r"^(?=.*\d)[A-Za-z0-9_\-]{10,}$|^\d+$|^[0-9a-f]{8,}$")
BATCH_LINE = re.compile(r"^(GET|POST|PUT|PATCH|DELETE) (\S+) HTTP/1\.1\r?$", re.MULTILINE)

IMAP_COMMANDS = {
    "CAPABILITY", "NOOP", "LOGOUT", "AUTHENTICATE", "LOGIN", "SELECT", "EXAMINE",
    "CREATE", "DELETE", "RENAME", "SUBSCRIBE", "UNSUBSCRIBE", "LIST", "LSUB", "XLIST",
    "STATUS", "APPEND", "CHECK", "CLOSE", "EXPUNGE", "SEARCH", "FETCH", "STORE", "COPY",
    "MOVE", "IDLE", "ID", "ENABLE", "NAMESPACE", "COMPRESS", "UNSELECT",
}
IMAP_RESPONSES = {
    "OK", "NO", "BAD", "BYE", "PREAUTH", "CAPABILITY", "LIST", "LSUB", "XLIST", "STATUS",
    "SEARCH", "FLAGS", "EXISTS", "RECENT", "EXPUNGE", "FETCH", "ENABLED", "ID",
    "NAMESPACE", "VANISHED",
}
IMAP_SAFE_MAILBOX = re.compile(r'^"?(INBOX|\[Gmail\]/[^"]+)"?$', re.IGNORECASE)
IMAP_COMMAND = re.compile(rb"^[A-Za-z0-9.]+ (UID )?([A-Z\-]+)(?: (.*))?$")
IMAP_UNTAGGED = re.compile(rb"^\* (?:\d+ )?([A-Z\-]+)")
IMAP_TAGGED = re.compile(rb"^[A-Za-z0-9.]+ (OK|NO|BAD)\b")
IMAP_FETCH_ITEMS = re.compile(rb"\(([A-Z0-9\-. \[\]]+)\)")


def redact_segment(segment: str) -> str:
    if "@" in segment or "%40" in segment.lower():
        return "{email}"
    if ID_SEGMENT.match(segment):
        return "{id}"
    return segment


def redact_query(query: str) -> dict:
    out = {}
    for key, value in parse_qsl(query, keep_blank_values=True):
        if key in SAFE_QUERY_VALUES or (key == "labelIds" and SYSTEM_LABEL.match(value)):
            kept = value
        else:
            kept = "<redacted>"
        out.setdefault(key, []).append(kept)
    return out


def redact_url(raw: str) -> dict:
    parts = urlsplit(raw)
    path = "/".join(redact_segment(seg) for seg in parts.path.split("/"))
    return {"path": path, "query": redact_query(parts.query)}


class RedactedCapture:
    def __init__(self):
        self.out = None

    def load(self, loader):
        loader.add_option("capture_out", str, "", "JSON Lines file for redacted records")

    def running(self):
        self.out = open(ctx.options.capture_out, "a", buffering=1)

    def write(self, record: dict):
        record["t"] = round(time.time(), 3)
        self.out.write(json.dumps(record) + "\n")

    def response(self, flow: http.HTTPFlow):
        req, resp = flow.request, flow.response
        record = {
            "kind": "http",
            "method": req.method,
            "host": req.pretty_host,
            "http_version": req.http_version,
            **redact_url(req.path),
            "status": resp.status_code,
            "req_bytes": len(req.raw_content or b""),
            "resp_bytes": len(resp.raw_content or b""),
            "ms": round(((resp.timestamp_end or resp.timestamp_start) - req.timestamp_start) * 1000),
            "x_goog_api_client": req.headers.get("x-goog-api-client"),
        }
        if "multipart/mixed" in req.headers.get("content-type", "") and req.raw_content:
            body = req.get_text(strict=False) or ""
            record["batch"] = [{"method": m, **redact_url(u)} for m, u in BATCH_LINE.findall(body)]
        self.write(record)

    def tcp_message(self, flow: tcp.TCPFlow):
        message = flow.messages[-1]
        for line in message.content.split(b"\r\n"):
            if message.from_client:
                self.client_line(line)
            else:
                self.server_line(line)

    def client_line(self, line: bytes):
        if line == b"DONE":
            self.write({"kind": "imap", "dir": "client", "command": "DONE"})
            return
        m = IMAP_COMMAND.match(line)
        if not m or m.group(2).decode() not in IMAP_COMMANDS:
            return
        name, args = m.group(2).decode(), m.group(3)
        detail = None
        if name in ("SELECT", "EXAMINE", "STATUS") and args:
            mailbox = args.decode(errors="replace").split(" (")[0]
            detail = mailbox if IMAP_SAFE_MAILBOX.match(mailbox) else "<redacted>"
        elif name in ("FETCH", "STORE") and args:
            items = IMAP_FETCH_ITEMS.findall(args)
            detail = items[-1].decode() if items else None
        command = ("UID " if m.group(1) else "") + name
        self.write({"kind": "imap", "dir": "client", "command": command, "detail": detail})

    def server_line(self, line: bytes):
        if line.startswith(b"+ "):
            self.write({"kind": "imap", "dir": "server", "response": "+"})
            return
        m = IMAP_UNTAGGED.match(line) or IMAP_TAGGED.match(line)
        if m and m.group(1).decode() in IMAP_RESPONSES:
            self.write({"kind": "imap", "dir": "server", "response": m.group(1).decode()})

    def done(self):
        if self.out:
            self.out.close()


addons = [RedactedCapture()]
