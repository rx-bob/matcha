import type { Story } from "../../../src/plan.ts"

const CLOSE_TRANSITION_MS = 230

export interface CloseStoryOptions {
  restoreFocus?: boolean
  immediate?: boolean
}

let storyOpener: HTMLElement | null = null
let motionVersion = 0
let closeTimer: ReturnType<typeof setTimeout> | null = null
let closePromise: Promise<boolean> | null = null
let resolveClose: ((closed: boolean) => void) | null = null

function dialogElement(): HTMLDialogElement | null {
  if (typeof document === "undefined") return null
  return document.getElementById("story-dialog") as HTMLDialogElement | null
}

function prefersReducedMotion(): boolean {
  return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches
}

/** Body scroll is locked while the mobile navigation drawer or the story dialog is open. */
export function syncScrollLock(): void {
  if (typeof document === "undefined") return
  const dialog = dialogElement()
  document.body.style.overflow =
    document.body.classList.contains("nav-open") || dialog?.open ? "hidden" : ""
}

export function isStoryOpen(): boolean {
  return dialogElement()?.open ?? false
}

export function openStoryId(): string | null {
  const dialog = dialogElement()
  return dialog?.open ? (dialog.dataset.story ?? null) : null
}

function riskLabel(risk: string): string {
  return `${risk[0].toUpperCase()}${risk.slice(1)} risk`
}

/**
 * Opens the story dialog with the content of a rendered story card. When the dialog is already
 * open (story-to-story navigation) the content is swapped in place and the original opener is kept.
 */
export function openStory(
  card: HTMLElement,
  story: Story,
  opener: Element | null = document.activeElement,
): void {
  const dialog = dialogElement()
  const content = document.getElementById("story-dialog-content")
  const title = document.getElementById("story-dialog-title")
  const idNode = document.getElementById("story-dialog-id")
  const riskNode = document.getElementById("story-dialog-risk")
  const feedback = document.getElementById("story-dialog-feedback")
  const sourceBody = card.querySelector<HTMLElement>(".story-body")

  if (!dialog || !content || !title || !idNode || !riskNode || !feedback || !sourceBody) return

  const version = ++motionVersion
  if (closeTimer !== null) clearTimeout(closeTimer)
  closeTimer = null
  resolveClose?.(false)
  closePromise = null
  resolveClose = null

  const alreadyOpen = dialog.open
  if (!alreadyOpen) storyOpener = (opener as HTMLElement | null) ?? null

  const body = sourceBody.cloneNode(true) as HTMLElement
  body.hidden = false
  body.querySelectorAll("[id]").forEach((node) => node.removeAttribute("id"))
  content.replaceChildren(body)

  const risk = story.risk ?? "medium"
  idNode.textContent = story.id
  title.textContent = story.title
  riskNode.textContent = riskLabel(risk)
  riskNode.className = `risk-badge ${risk}`
  dialog.dataset.story = story.id
  feedback.hidden = true

  if (!alreadyOpen) {
    dialog.classList.remove("is-visible")
    dialog.showModal()
  }

  syncScrollLock()
  content.scrollTop = 0
  title.focus({ preventScroll: true })

  if (alreadyOpen || prefersReducedMotion()) {
    dialog.classList.add("is-visible")
  } else {
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        if (dialog.open && version === motionVersion) dialog.classList.add("is-visible")
      }),
    )
  }
}

/** Closes the dialog after its exit transition. Resolves true once closed, false if reopened. */
export function closeStory({ restoreFocus = true, immediate = false }: CloseStoryOptions = {}): Promise<boolean> {
  const dialog = dialogElement()
  if (!dialog || !dialog.open) return Promise.resolve(true)
  if (closePromise) return closePromise

  motionVersion++
  dialog.classList.remove("is-visible")
  const feedback = document.getElementById("story-dialog-feedback")
  if (feedback) feedback.hidden = true

  const result = new Promise<boolean>((resolve) => {
    resolveClose = resolve
  })
  closePromise = result

  const finish = (): void => {
    closeTimer = null
    const resolve = resolveClose
    resolveClose = null
    closePromise = null

    dialog.close()
    document.getElementById("story-dialog-content")?.replaceChildren()
    delete dialog.dataset.story
    syncScrollLock()

    const opener = storyOpener
    storyOpener = null
    if (restoreFocus && opener?.isConnected && opener.getClientRects().length > 0) {
      opener.focus({ preventScroll: true })
    }
    resolve?.(true)
  }

  if (immediate || prefersReducedMotion()) finish()
  else closeTimer = setTimeout(finish, CLOSE_TRANSITION_MS)

  return result
}

function pointerOutside(dialog: HTMLElement, event: MouseEvent): boolean {
  const rect = dialog.getBoundingClientRect()
  return (
    event.clientX < rect.left ||
    event.clientX > rect.right ||
    event.clientY < rect.top ||
    event.clientY > rect.bottom
  )
}

/**
 * Wires the dialog's own close affordances: close button, Escape (cancel) and backdrop click.
 * `onDismiss` is invoked for user-initiated dismissals so the router can reset the hash.
 */
export function initStoryDialog(onDismiss: () => void): () => void {
  const dialog = dialogElement()
  const closeButton = document.getElementById("close-story")
  if (!dialog) return () => {}

  let backdropPressed = false

  const dismiss = (): void => {
    onDismiss()
    void closeStory()
  }
  const onCancel = (event: Event): void => {
    event.preventDefault()
    dismiss()
  }
  const onPointerDown = (event: PointerEvent): void => {
    backdropPressed = event.button === 0 && event.target === dialog && pointerOutside(dialog, event)
  }
  const onPointerCancel = (): void => {
    backdropPressed = false
  }
  const onClick = (event: MouseEvent): void => {
    if (backdropPressed && event.target === dialog && pointerOutside(dialog, event)) dismiss()
    backdropPressed = false
  }

  closeButton?.addEventListener("click", dismiss)
  dialog.addEventListener("cancel", onCancel)
  dialog.addEventListener("pointerdown", onPointerDown)
  dialog.addEventListener("pointercancel", onPointerCancel)
  dialog.addEventListener("click", onClick)

  return () => {
    closeButton?.removeEventListener("click", dismiss)
    dialog.removeEventListener("cancel", onCancel)
    dialog.removeEventListener("pointerdown", onPointerDown)
    dialog.removeEventListener("pointercancel", onPointerCancel)
    dialog.removeEventListener("click", onClick)
  }
}
