# Isolated wallet integration test

The helper unlocks an existing KDE wallet through KDE's PAM startup protocol. It requires Linux, KWallet 6.29 or newer, Python 3, and python-dbus. Native unit tests mock this flow on other systems.

Test wallet changes on Linux in a separate D-Bus session with temporary home and XDG directories. Never run this test against your live wallet:

```sh
repo=$(pwd)
fixture=$(mktemp -d)
mkdir -m 700 "$fixture/home" "$fixture/data" "$fixture/config" "$fixture/runtime"
env DESKTOP_WALLET_TEST=isolated \
  HOME="$fixture/home" XDG_DATA_HOME="$fixture/data" \
  XDG_CONFIG_HOME="$fixture/config" XDG_RUNTIME_DIR="$fixture/runtime" \
  dbus-run-session -- python3 "$repo/tools/desktop/test-wallet.py"
```

The test creates a disposable wallet and credential. It checks that a wrong password leaves the wallet unchanged, the correct password restores the saved credential, and repeated unlocks do not restart an already-open wallet. Delete the temporary fixture afterwards.
