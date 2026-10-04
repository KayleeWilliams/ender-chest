"""Unlock the existing KDE wallet through KDE's PAM startup protocol.

Passwords arrive on stdin or through getpass, never argv or the environment.
Requires Linux, python-dbus, and KWallet 6.29's PAM instance replacement.
"""
import fcntl
import getpass
import hashlib
import os
from pathlib import Path
import resource
import secrets
import socket
import subprocess
import sys
import tempfile
import time

SERVICE = "org.freedesktop.secrets"
COLLECTION = "/org/freedesktop/secrets/collection/kdewallet"


def locked(bus):
    import dbus
    obj = bus.get_object(SERVICE, COLLECTION)
    return bool(dbus.Interface(obj, "org.freedesktop.DBus.Properties").Get(
        "org.freedesktop.Secret.Collection", "Locked", timeout=5))


def pam_launch(password, salt, runtime, env):
    """Supply the same derived key and inherited descriptors as pam_kwallet."""
    key = bytearray(hashlib.pbkdf2_hmac("sha512", password, salt, 50000, 56))
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, key)
    finally:
        key[:] = b"\0" * len(key)
        os.close(write_fd)
    try:
        with socket.socket(socket.AF_UNIX) as listener, tempfile.TemporaryFile(dir=runtime) as log:
            address = "\0ender-wallet-" + secrets.token_hex(16)
            listener.bind(address)
            listener.listen(1)
            # Startup diagnostics contain no password or derived key. The file
            # is anonymous and is never copied into configuration or the repo.
            child_env = {**env, "PAM_KWALLET5_LOGIN": "1",
                         "QT_FORCE_STDERR_LOGGING": "1", "QT_LOGGING_TO_CONSOLE": "1",
                         "QT_LOGGING_RULES": "*.debug=false;kf.wallet.ksecretd.debug=true"}
            proc = subprocess.Popen(
                ["/usr/bin/ksecretd", "--pam-login", str(read_fd), str(listener.fileno())],
                pass_fds=(read_fd, listener.fileno()), env=child_env,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log,
                start_new_session=True,
            )
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(address)
                # KDE already inherited the session environment; EOF completes
                # its environment handshake without putting secrets in it.
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                output = os.pread(log.fileno(), 65536, 0)
                if b"Wallet opened by PAM" in output:
                    return proc
                if b"Wallet failed to get opened by PAM" in output:
                    raise RuntimeError("Wallet password was rejected. Run desktop auth --setup on your Mac to replace it.")
                if proc.poll() is not None:
                    raise RuntimeError("KDE's wallet service exited before unlocking.")
                time.sleep(0.05)
            raise RuntimeError("KDE's wallet unlock timed out. This helper requires KWallet 6.29 or newer.")
    finally:
        os.close(read_fd)


def activate_collection(bus):
    import dbus
    service = dbus.Interface(bus.get_object(SERVICE, "/org/freedesktop/secrets"), "org.freedesktop.Secret.Service")
    _, prompt = service.Unlock([dbus.ObjectPath(COLLECTION)], timeout=5)
    if str(prompt) != "/":
        # PAM has already verified the password. This attaches the Secret
        # Service collection to the open backend without asking for a password.
        dbus.Interface(bus.get_object(SERVICE, prompt), "org.freedesktop.Secret.Prompt").Prompt("", timeout=5)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not locked(bus):
            return
        time.sleep(0.05)
    raise RuntimeError("KDE opened the wallet, but its credential service did not become ready.")


def main():
    if sys.argv[1:] not in ([], ["--status"], ["--prompt"]):
        raise RuntimeError("Usage: unlock-wallet.py [--status | --prompt]")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    if not runtime.is_dir() or runtime.stat().st_uid != os.getuid():
        raise RuntimeError("The desktop user session is not running yet.")
    os.environ.setdefault("XDG_RUNTIME_DIR", str(runtime))
    os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={runtime}/bus")
    import dbus
    bus = dbus.SessionBus()
    if sys.argv[1:] == ["--status"]:
        print("locked" if locked(bus) else "unlocked")
        return
    # Serialize attempts, including the already-unlocked check.
    fd = os.open(runtime / "ender-wallet-auth.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another wallet unlock is already in progress.") from None
        if not locked(bus):
            print("Desktop wallet is already unlocked.")
            return
        data = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "kwalletd"
        if not (data / "kdewallet.kwl").is_file():
            raise RuntimeError("No existing kdewallet found. Create it in KDE Wallet Manager first.")
        salt = (data / "kdewallet.salt").read_bytes()
        if len(salt) != 56:
            raise RuntimeError("This wallet does not have a supported PAM salt.")
        if sys.argv[1:] == ["--prompt"]:
            if not sys.stdin.isatty():
                raise RuntimeError("A terminal is required for the wallet password prompt.")
            password = bytearray(getpass.getpass("KWallet password: ").encode())
        else:
            password = bytearray(sys.stdin.buffer.read(4097))
        try:
            if not password or len(password) > 4096 or b"\0" in password or b"\n" in password:
                raise RuntimeError("Expected a nonempty wallet password on stdin, without a newline.")
            env = dict(os.environ)
            # An SSH session lacks Wayland variables. Preserve the graphical
            # environment so future ordinary wallet dialogs still work.
            session = subprocess.run(["systemctl", "--user", "show-environment"], capture_output=True, text=True, timeout=5)
            for line in session.stdout.splitlines():
                name, _, value = line.partition("=")
                if name in {"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP"}:
                    env[name] = value
            pam_launch(password, salt, runtime, env)
        finally:
            password[:] = b"\0" * len(password)
        activate_collection(bus)
        print("Desktop wallet unlocked. Git and other apps can now use its saved credentials.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Wallet unlock cancelled.", file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # Do not include subprocess input, secret values, or daemon logs.
        print(f"Wallet unlock failed: {error}", file=sys.stderr)
        sys.exit(1)
