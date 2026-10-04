import { defineConfig } from "oxfmt";
import ultracite from "ultracite/oxfmt";

export default defineConfig({
  ...ultracite,
  ignorePatterns: [
    ...ultracite.ignorePatterns,
    "tools/oxlint/anti-slop/**",
    "**/.zig-cache/**",
    "**/zig-out/**",
    "**/zig-pkg/**",
  ],
});
