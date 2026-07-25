import { svelte } from "@sveltejs/vite-plugin-svelte"
import { defineConfig } from "vite"

export default defineConfig(({ mode }) => {
  const isMap = mode === "map"
  const isServe = mode === "serve"

  return {
    plugins: [svelte()],
    build: {
      outDir: "dist",
      emptyOutDir: false,
      lib: {
        entry: isMap ? "src/map.ts" : isServe ? "src/serve.ts" : "src/main.ts",
        name: isMap ? "BobMapClient" : isServe ? "BobServeClient" : "BobPlanClient",
        formats: ["iife"],
        fileName: () => isMap ? "map.js" : isServe ? "serve.js" : "plan.js",
        cssFileName: isMap ? "map" : isServe ? "serve" : "plan",
      },
      rollupOptions: {
        output: {
          inlineDynamicImports: true,
        },
      },
    },
  }
})
