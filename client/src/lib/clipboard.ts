import { showToast } from "./toast"

export async function copyText(text: string, label = "Copied to clipboard"): Promise<void> {
  try {
    if (
      typeof navigator === "undefined" ||
      !navigator.clipboard ||
      typeof window === "undefined" ||
      !window.isSecureContext
    ) {
      throw new Error("Clipboard API unavailable")
    }
    await navigator.clipboard.writeText(text)
    showToast(label)
  } catch {
    if (typeof document === "undefined") return
    const helper = document.createElement("textarea")
    helper.value = text
    helper.style.cssText = "position:fixed;left:-9999px;top:0"
    const previousFocus = document.activeElement as HTMLElement | null
    // Content outside the topmost modal is inert, including temporary copy inputs.
    const container = previousFocus?.closest("dialog[open]") ?? document.body
    container.appendChild(helper)
    helper.focus()
    helper.select()
    let copied = false
    try {
      copied = document.execCommand("copy")
    } catch {}
    helper.remove()
    if (previousFocus?.isConnected) previousFocus.focus({ preventScroll: true })
    if (copied) {
      showToast(label)
    } else {
      const copyDialog = document.getElementById("copy-dialog") as HTMLDialogElement | null
      const copyTextEl = document.getElementById("copy-text") as HTMLTextAreaElement | null
      if (copyDialog && copyTextEl) {
        copyTextEl.value = text
        copyDialog.showModal()
        copyTextEl.focus()
        copyTextEl.select()
      }
    }
  }
}

export function initClipboardDelegation(): () => void {
  if (typeof document === "undefined") return () => {}

  function handleClick(event: MouseEvent) {
    const target = event.target as HTMLElement | null
    if (!target) return

    const path = target.closest<HTMLElement>("[data-copy-path]")
    if (path && path.dataset.copyPath) {
      event.preventDefault()
      copyText(path.dataset.copyPath, "Local reference path copied")
      return
    }

    const code = target.closest<HTMLElement>("[data-copy-code]")
    if (code) {
      event.preventDefault()
      const example = code.closest(".code-example")
      const pre = example?.querySelector("pre")
      if (pre?.textContent) {
        copyText(pre.textContent, "Code example copied")
      }
    }
  }

  document.addEventListener("click", handleClick)
  return () => {
    document.removeEventListener("click", handleClick)
  }
}
