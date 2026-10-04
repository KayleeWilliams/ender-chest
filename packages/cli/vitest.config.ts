import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    name: "cli",
    root: import.meta.dirname,
    testTimeout: 15_000,
  },
});
