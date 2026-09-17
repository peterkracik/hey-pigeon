import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// Port + outDir pinned to Tauri defaults so tauri.conf.json slots in later without churn
export default defineConfig({
  plugins: [svelte()],
  server: { port: 1420, strictPort: true },
  build: { outDir: "dist" },
});
