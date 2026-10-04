#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const fail = (message) => {
  process.stderr.write(`ec: ${message}\n`);
  process.exit(1);
};

if (
  !["darwin", "linux"].includes(process.platform) ||
  !["arm64", "x64"].includes(process.arch)
) {
  fail("Supported systems are macOS and Linux on ARM64 or x86-64.");
}
const os = process.platform === "darwin" ? "macos" : "linux";
const arch = process.arch === "arm64" ? "aarch64" : "x86_64";
const binary = fileURLToPath(
  new URL(`../native/ec-${arch}-${os}`, import.meta.url)
);
const result = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  fail(`Cannot launch the installed binary: ${result.error.message}`);
}
if (result.signal) {
  process.kill(process.pid, result.signal);
} else {
  process.exit(result.status ?? 1);
}
