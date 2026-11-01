let toastTimer: ReturnType<typeof setTimeout> | undefined

export function showToast(message: string): void {
  if (typeof document === "undefined") return
  const storyDialog = document.getElementById("story-dialog") as HTMLDialogElement | null
  const storyFeedback = document.getElementById("story-dialog-feedback")
  const toastEl = document.getElementById("toast")

  const target = storyDialog?.open && storyFeedback ? storyFeedback : toastEl
  if (!target) return

  if (toastTimer) clearTimeout(toastTimer)
  if (toastEl) toastEl.hidden = true
  if (storyFeedback) storyFeedback.hidden = true

  target.textContent = message
  target.hidden = false
  toastTimer = setTimeout(() => {
    target.hidden = true
  }, 3200)
}
