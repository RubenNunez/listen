#!/usr/bin/env python3
"""Loopback-only synthetic MCP fixture. No real hardware, model, credential or shell access."""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--sse", action="store_true")
    args = parser.parse_args()
    lock = threading.Lock()
    state = {"calls": [], "synthetic": True}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 65536:
                self.send_error(413)
                return
            message = json.loads(self.rfile.read(length))
            method, request_id = message.get("method"), message.get("id")
            params = message.get("params", {})
            version = self.headers.get("MCP-Protocol-Version")
            if version not in ("2026-07-28", "2025-11-25"):
                self.send_error(400)
                return
            if version == "2026-07-28":
                if params.get("_meta", {}).get("io.modelcontextprotocol/protocolVersion") != version or self.headers.get("Mcp-Method") != method:
                    self.send_error(400)
                    return
            if method == "initialize":
                result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "Listen synthetic fixture", "version": "1"}}
            elif method == "notifications/initialized":
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            elif method == "tools/list":
                result = {"tools": [{"name": "set_light", "description": "Set the simulated lamp on or off. This is synthetic, not real home automation.", "inputSchema": {"type": "object", "properties": {"on": {"type": "boolean"}}, "required": ["on"], "additionalProperties": False}}]}
            elif method == "tools/call" and params.get("name") == "set_light" and set(params.get("arguments", {})) == {"on"} and isinstance(params["arguments"]["on"], bool):
                with lock:
                    state["calls"].append({"on": params["arguments"]["on"]})
                    args.state.write_text(json.dumps(state))
                result = {"content": [{"type": "text", "text": "Die simulierte Lampe ist " + ("eingeschaltet." if params["arguments"]["on"] else "ausgeschaltet.")}], "isError": False}
            else:
                result = {"content": [{"type": "text", "text": "Unsupported synthetic request."}], "isError": True}
            payload = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}).encode()
            if args.sse:
                payload = b": synthetic keepalive\n\ndata: " + payload + b"\n\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream" if args.sse else "application/json")
            if method == "initialize":
                self.send_header("Mcp-Session-Id", "synthetic-session")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    args.state.parent.mkdir(parents=True, exist_ok=True)
    args.state.write_text(json.dumps(state))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http://127.0.0.1:{server.server_port}/mcp", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
