# Devices

The machines this config syncs, so agents know which machine to reach and how. Replace the example rows with your own, and keep this repository private once it lists real hostnames. No secrets belong in this file.

| Machine | Hostname | OS | SSH user | Config checkout | Role |
| --- | --- | --- | --- | --- | --- |
| Laptop | `laptop.tailnet-name.ts.net` | macOS | `you` | `~/my-machine-config` | Primary machine |
| Server | `server.tailnet-name.ts.net` | Linux | `you` | `~/my-machine-config` | Always on |

[Devices](https://github.com/KayleeWilliams/ender-chest/blob/main/docs/devices.md) covers `ec status`, `ec sync --all`, and the SSH and GitHub access they need.
