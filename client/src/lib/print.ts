interface PrintState {
  theme: string | undefined
  details: Array<[HTMLDetailsElement, boolean]>
  hidden: Array<[HTMLElement, boolean]>
}

/**
 * Before printing: expands every `<details>`, reveals filtered cards and forces the light theme.
 * After printing: restores all of it. Returns a cleanup function.
 */
export function initPrintHandlers(): () => void {
  if (typeof window === "undefined") return () => {}
  let state: PrintState | null = null

  function beforePrint(): void {
    if (state) return
    const root = document.documentElement
    state = {
      theme: root.dataset.theme,
        details: Array.from(document.querySelectorAll<HTMLDetailsElement>("details")).map((node) => [node, node.open]),
      hidden: Array.from(document.querySelectorAll<HTMLElement>(".epic-card, .story-card")).map((node) => [
        node,
        node.hidden,
      ]),
    }
    state.details.forEach(([node]) => {
      node.open = true
    })
    state.hidden.forEach(([node]) => {
      node.hidden = false
    })
    root.dataset.theme = "light"
  }

  function afterPrint(): void {
    if (!state) return
    state.details.forEach(([node, open]) => {
      node.open = open
    })
    state.hidden.forEach(([node, hidden]) => {
      node.hidden = hidden
    })
    if (state.theme) document.documentElement.dataset.theme = state.theme
    else delete document.documentElement.dataset.theme
    state = null
  }

  window.addEventListener("beforeprint", beforePrint)
  window.addEventListener("afterprint", afterPrint)
  return () => {
    window.removeEventListener("beforeprint", beforePrint)
    window.removeEventListener("afterprint", afterPrint)
  }
}
