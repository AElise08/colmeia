#!/usr/bin/env python3
"""E2E test for Colmeia Hub — tests the full web bootstrap flow."""
import json, socket, base64, struct, sys, os, time

HOST = os.environ.get("HUB_HOST", "127.0.0.1")
PORT = int(os.environ.get("HUB_PORT", "9620"))
TOKEN = os.environ.get("HUB_TOKEN", "")

passed = 0
failed = 0

def ws_connect():
    sock = socket.socket()
    sock.settimeout(10)
    sock.connect((HOST, PORT))
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((
        f"GET / HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += sock.recv(4096)
    if b"101" not in buf.split(b"\r\n")[0]:
        raise Exception("WebSocket handshake failed: " + buf.decode())
    return sock

def ws_send(sock, data):
    d = json.dumps(data).encode()
    frame = bytearray([0x81])
    if len(d) < 126:
        frame.append(len(d))
    elif len(d) < 65536:
        frame.extend([126, (len(d) >> 8) & 0xFF, len(d) & 0xFF])
    else:
        frame.append(127)
        frame.extend(struct.pack(">Q", len(d)))
    frame.extend(d)
    sock.sendall(bytes(frame))

def ws_recv(sock):
    b = sock.recv(2)
    mlen = b[1] & 0x7F
    if mlen == 126:
        mlen = struct.unpack(">H", sock.recv(2))[0]
    elif mlen == 127:
        mlen = struct.unpack(">Q", sock.recv(8))[0]
    payload = b""
    while len(payload) < mlen:
        payload += sock.recv(mlen - len(payload))
    return json.loads(payload.decode())

def ws_recv_response(sock, request_id):
    while True:
        message = ws_recv(sock)
        if message.get("kind") == "response" and message.get("id") == request_id:
            return message

def test(name, fn):
    global passed, failed
    try:
        fn()
        passed += 1
        print(f"  ✅ {name}")
    except Exception as e:
        failed += 1
        print(f"  ❌ {name}: {e}")

# ── Tests ──────────────────────────────────────────────────────────────
def test_hello():
    ws = ws_connect()
    ws_send(ws, {"kind":"request","id":"h1","method":"hello",
        "params":{"protocol_version":1,"client":"py-test","author":"humano:py-test","token":TOKEN}})
    r = ws_recv_response(ws, "h1")
    assert r["ok"] == True, f"hello failed: {r}"
    ws.close()

def test_create_room():
    ws = ws_connect()
    ws_send(ws, {"kind":"request","id":"c1","method":"hello",
        "params":{"protocol_version":1,"client":"py-test","author":"humano:py-test","token":TOKEN}})
    ws_recv_response(ws, "c1")
    ws_send(ws, {"kind":"request","id":"c2","method":"room.create","params":{"name":"E2E Test"}})
    r = ws_recv_response(ws, "c2")
    assert r["ok"] == True, f"create failed: {r}"
    assert "room" in r["result"], f"no room in result: {r}"
    assert "id" in r["result"]["room"], f"no room.id: {r}"
    global test_room_id
    test_room_id = r["result"]["room"]["id"]
    ws.close()

def test_create_invite():
    ws = ws_connect()
    ws_send(ws, {"kind":"request","id":"i1","method":"hello",
        "params":{"protocol_version":1,"client":"py-test","author":"humano:py-test","token":TOKEN}})
    ws_recv_response(ws, "i1")
    ws_send(ws, {"kind":"request","id":"i2","method":"member.invite",
        "params":{"room_id":test_room_id,"display_name":"Convite Test","roles":["editor"]}})
    r = ws_recv_response(ws, "i2")
    assert r["ok"] == True, f"invite failed: {r}"
    global test_invite_token
    test_invite_token = r["result"]["invite_token"]
    ws.close()

def test_join_with_invite():
    ws = ws_connect()
    ws_send(ws, {"kind":"request","id":"j1","method":"hello",
        "params":{"protocol_version":1,"client":"web-browser","author":"humano:web-user","token":test_invite_token}})
    r = ws_recv_response(ws, "j1")
    assert r["ok"] == True, f"hello with invite failed: {r}"
    ws_send(ws, {"kind":"request","id":"j2","method":"room.join",
        "params":{"room_id":test_room_id,"invite_token":test_invite_token}})
    r = ws_recv_response(ws, "j2")
    assert r["ok"] == True, f"join failed: {r}"
    assert r["result"]["room"]["name"] == "E2E Test"
    assert len(r["result"]["members"]) > 0
    ws.close()

    ws = ws_connect()
    ws_send(ws, {"kind":"request","id":"jr1","method":"hello",
        "params":{"protocol_version":1,"client":"web-browser","author":"humano:web-user","token":test_invite_token}})
    r = ws_recv_response(ws, "jr1")
    assert r["ok"] == True, f"reconnect hello failed: {r}"
    ws_send(ws, {"kind":"request","id":"jr2","method":"room.join",
        "params":{"room_id":test_room_id,"invite_token":test_invite_token}})
    r = ws_recv_response(ws, "jr2")
    assert r["ok"] == True, f"reconnect join failed: {r}"
    ws.close()

def test_snapshot():
    ws = ws_connect()
    ws_send(ws, {"kind":"request","id":"s1","method":"hello",
        "params":{"protocol_version":1,"client":"py-test","author":"humano:py-test","token":TOKEN}})
    ws_recv_response(ws, "s1")
    ws_send(ws, {"kind":"request","id":"s2","method":"room.snapshot",
        "params":{"room_id":test_room_id}})
    r = ws_recv_response(ws, "s2")
    assert r["ok"] == True, f"snapshot failed: {r}"
    assert "members" in r["result"]
    assert len(r["result"]["members"]) > 0
    assert "display_name" in r["result"]["members"][0]
    ws.close()

def test_chat_persistence():
    ws = ws_connect()
    ws_send(ws, {"kind":"request","id":"m1","method":"hello",
        "params":{"protocol_version":1,"client":"py-test","author":"humano:py-test","token":TOKEN}})
    ws_recv_response(ws, "m1")
    ws_send(ws, {"kind":"request","id":"m2","method":"room.join",
        "params":{"room_id":test_room_id}})
    ws_recv_response(ws, "m2")
    ws_send(ws, {"kind":"request","id":"m3","method":"agent_session.create",
        "params":{"room_id":test_room_id,"workspace_id":test_room_id,
                  "node_id":test_room_id,"objective":"Chat E2E"}})
    session = ws_recv_response(ws, "m3")["result"]["agent_session"]
    ws_send(ws, {"kind":"request","id":"m4","method":"session_event.append",
        "params":{"room_id":test_room_id,"session_id":session["id"],
                  "kind":"message_sent","payload":{"texto":"Mensagem E2E"},
                  "event_id":test_room_id}})
    r = ws_recv_response(ws, "m4")
    assert r["ok"] == True, f"chat append failed: {r}"
    ws_send(ws, {"kind":"request","id":"m5","method":"room.snapshot",
        "params":{"room_id":test_room_id}})
    events = ws_recv_response(ws, "m5")["result"]["events"]
    assert any(e.get("payload", {}).get("texto") == "Mensagem E2E" for e in events)
    ws.close()

def test_html_join_page():
    import urllib.request
    url = f"http://{HOST}/join/{test_room_id}/{test_invite_token}" if HOST != "127.0.0.1" \
        else f"http://{HOST}:{PORT}/join/{test_room_id}/{test_invite_token}"
    resp = urllib.request.urlopen(url, timeout=5)
    body = resp.read().decode()
    assert resp.status == 200
    assert "window.bootReady" in body
    assert "pendingRequests" in body
    assert "display_name" in body
    assert "note-checkbox" in body
    assert "watchdog_configuration" in body
    assert "Navegador" in body
    assert "safePortalURL" in body
    assert "portal-open" in body
    assert "Cache-Control" not in body  # header not in body, check via headers
    print(f"    HTML size: {len(body)} bytes")

def test_html_cache_control():
    import urllib.request
    url = f"http://{HOST}/join/x/y" if HOST != "127.0.0.1" \
        else f"http://{HOST}:{PORT}/join/x/y"
    req = urllib.request.Request(url, method="GET")
    resp = urllib.request.urlopen(req, timeout=5)
    cc = resp.headers.get("Cache-Control", "")
    assert "no-store" in cc, f"Cache-Control missing no-store: {cc}"

def test_invalid_invite_propagates_error():
    ws = ws_connect()
    ws_send(ws, {"kind":"request","id":"e1","method":"hello",
        "params":{"protocol_version":1,"client":"web-browser","author":"humano:web-user","token":"INVALID_TOKEN"}})
    ws_recv(ws)
    ws_send(ws, {"kind":"request","id":"e2","method":"room.join",
        "params":{"room_id":test_room_id,"invite_token":"INVALID_TOKEN"}})
    r = ws_recv(ws)
    assert r["ok"] == False, "expected join to fail with invalid invite"
    assert "error" in r, f"no error field: {r}"
    ws.close()

def test_cleanup_test_rooms():
    ws = ws_connect()
    ws_send(ws, {"kind":"request","id":"d1","method":"hello",
        "params":{"protocol_version":1,"client":"py-test","author":"humano:py-test","token":TOKEN}})
    ws_recv_response(ws, "d1")
    ws_send(ws, {"kind":"request","id":"d2","method":"room.list","params":{}})
    rooms = ws_recv_response(ws, "d2")["result"]
    for index, room in enumerate(rooms):
        if room.get("name") != "E2E Test":
            continue
        request_id = f"d{index + 3}"
        ws_send(ws, {"kind":"request","id":request_id,"method":"room.delete",
            "params":{"room_id":room["id"],"confirmar":True}})
        response = ws_recv_response(ws, request_id)
        assert response["ok"] == True, f"cleanup failed: {response}"
    ws.close()

# ── Run ────────────────────────────────────────────────────────────────
print(f"\n🌐 Colmeia Hub E2E — {HOST}:{PORT}\n")

test_room_id = None
test_invite_token = None

test("Hello with master token", test_hello)
test("Create room", test_create_room)
test("Create invite", test_create_invite)
test("Join room with invite", test_join_with_invite)
test("Chat persists in room", test_chat_persistence)
test("Room snapshot", test_snapshot)
test("Invalid invite propagates error", test_invalid_invite_propagates_error)
test("HTML join page contains JS fixes", test_html_join_page)
test("HTML Cache-Control: no-store", test_html_cache_control)
test("Cleanup E2E rooms", test_cleanup_test_rooms)

print(f"\n{'='*40}")
print(f"  Passed: {passed}  Failed: {failed}")
print(f"{'='*40}")
sys.exit(0 if failed == 0 else 1)
