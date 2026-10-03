"""Run with dbus-run-session in an isolated temporary HOME, never a live session."""
import atexit
import hashlib
import importlib.util
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys

sys.dont_write_bytecode = True

import dbus

if os.environ.get("DESKTOP_WALLET_TEST") != "isolated":
    raise SystemExit("Use the isolated test command in tools/desktop/README.md.")

helper = Path(__file__).resolve().parents[2] / "examples/config/home/.local/lib/desktop/unlock-wallet.py"
spec = importlib.util.spec_from_file_location("wallet_helper", helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
data = Path(os.environ["XDG_DATA_HOME"]) / "kwalletd"
data.mkdir(parents=True)
salt = secrets.token_bytes(56)
(data / "kdewallet.salt").write_bytes(salt)
password = secrets.token_urlsafe(24).encode()
module.pam_launch(password, salt, Path(os.environ["XDG_RUNTIME_DIR"]), dict(os.environ))
bus = dbus.SessionBus()

def cleanup():
    try:
        daemon = dbus.Interface(bus.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus"), "org.freedesktop.DBus")
        os.kill(int(daemon.GetConnectionUnixProcessID(module.SERVICE)), signal.SIGTERM)
    except dbus.DBusException:
        pass

atexit.register(cleanup)
module.activate_collection(bus)
service = dbus.Interface(bus.get_object(module.SERVICE, "/org/freedesktop/secrets"), "org.freedesktop.Secret.Service")
_, session = service.OpenSession("plain", dbus.String("", variant_level=1))
collection = dbus.Interface(bus.get_object(module.SERVICE, module.COLLECTION), "org.freedesktop.Secret.Collection")
credential = secrets.token_bytes(24)
item, prompt = collection.CreateItem({
    "org.freedesktop.Secret.Item.Label": dbus.String("Desktop auth test"),
    "org.freedesktop.Secret.Item.Attributes": dbus.Dictionary({"application": "ender-test"}, signature="ss"),
}, (session, dbus.ByteArray(b""), dbus.ByteArray(credential), "application/octet-stream"), False)
assert str(prompt) == "/"

def run(*args, secret=None):
    return subprocess.run([sys.executable, str(helper), *args], input=secret, capture_output=True, timeout=20)

assert run("--status").stdout.strip() == b"unlocked"
# An already-open wallet must not consume stdin or restart its service.
owner = bus.get_name_owner(module.SERVICE)
assert run().returncode == 0
assert bus.get_name_owner(module.SERVICE) == owner
service.Lock([dbus.ObjectPath(module.COLLECTION)])
assert run("--status").stdout.strip() == b"locked"
before = hashlib.sha256((data / "kdewallet.kwl").read_bytes()).digest()
bad = run(secret=b"wrong-password")
assert bad.returncode == 1, bad.stdout
assert b"rejected" in bad.stderr, bad.stderr
assert run("--status").stdout.strip() == b"locked"
assert hashlib.sha256((data / "kdewallet.kwl").read_bytes()).digest() == before
good = run(secret=password)
assert good.returncode == 0, good.stderr
assert run("--status").stdout.strip() == b"unlocked"
assert password not in good.stdout + good.stderr
service = dbus.Interface(bus.get_object(module.SERVICE, "/org/freedesktop/secrets"), "org.freedesktop.Secret.Service")
_, session = service.OpenSession("plain", dbus.String("", variant_level=1))
unlocked, waiting = service.SearchItems({"application": "ender-test"})
assert len(unlocked) == 1 and not waiting
entry = dbus.Interface(bus.get_object(module.SERVICE, unlocked[0]), "org.freedesktop.Secret.Item")
assert bytes(entry.GetSecret(session)[2]) == credential
print("PASS: wrong password leaves wallet unchanged; correct password restores access to the saved credential; repeated auth is harmless.")
