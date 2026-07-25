import ServeApp from "./ServeApp.svelte"
import { mount } from "svelte"

const target = document.getElementById("serve-root")

if (!target) {
  console.warn("Serve content target was not found: #serve-root")
} else {
  target.textContent = ""

  mount(ServeApp, {
    target,
    props: {
      catalogUrl: "/api/catalog",
    },
  })
}
