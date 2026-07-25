import ServeApp from "./ServeApp.svelte"
import { mount } from "svelte"

const target = document.getElementById("serve-root")

if (!target) {
  throw new Error("Serve content target was not found")
}

target.textContent = ""

mount(ServeApp, {
  target,
  props: {
    catalogUrl: "/api/catalog",
  },
})
