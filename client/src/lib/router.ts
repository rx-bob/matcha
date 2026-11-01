import type { Plan, Story } from "../../../src/plan.ts"
import { isViewId, targetForHash, type ViewId } from "./ids"
import { closeStory, isStoryOpen, openStory } from "./storyDialog"

export const CLEAR_STORY_FILTERS_EVENT = "matcha:clear-story-filters"

const SPOTLIGHT_MS = 1900

export interface RouterHost {
  plan: Plan
  getView(): string
  /** Switches the visible workspace view and resolves once the DOM reflects it. */
  setView(view: ViewId): Promise<void>
  /** Closes transient chrome (mobile navigation drawer, export menu) before navigating. */
  dismissChrome(): void
}

export interface Router {
  route(hash?: string, focus?: boolean): Promise<void>
  go(hash: string): void
  /** Resets a story hash back to the current view after the user dismissed the dialog. */
  onStoryDismissed(): void
  start(): () => void
}

function findStory(plan: Plan, id: string | undefined): Story | null {
  if (!id) return null
  for (const epic of plan.epics ?? []) {
    const story = epic.stories?.find((candidate) => candidate.id === id)
    if (story) return story
  }
  return null
}

function storyCardOf(target: Element | null): HTMLElement | null {
  return target?.closest<HTMLElement>(".story-card") ?? null
}

function prefersReducedMotion(): boolean {
  return matchMedia("(prefers-reduced-motion: reduce)").matches
}

function spotlightNode(target: HTMLElement): HTMLElement {
  if (target.matches(".epic-card")) {
    return target.querySelector<HTMLElement>(".epic-header") ?? target
  }
  return target.closest<HTMLElement>(".story-card, .epic-header, .context-card, .file-row") ?? target
}

function focusTarget(target: HTMLElement, page: HTMLElement): void {
  let focusNode: HTMLElement | null
  if (target.matches("details")) focusNode = target.querySelector<HTMLElement>("summary")
  else if (target === page) focusNode = page.querySelector<HTMLElement>("h1")
  else focusNode = target

  if (!focusNode) return
  if (!focusNode.matches("a, button, summary, input")) focusNode.tabIndex = -1
  focusNode.focus({ preventScroll: true })
}

function spotlight(target: HTMLElement): void {
  const node = spotlightNode(target)
  node.classList.remove("spotlight")
  void node.offsetWidth
  node.classList.add("spotlight")
  setTimeout(() => node.classList.remove("spotlight"), SPOTLIGHT_MS)
}

export function createRouter(host: RouterHost): Router {
  let routeVersion = 0

  function showStory(card: HTMLElement, opener?: Element | null): void {
    const story = findStory(host.plan, card.dataset.story)
    if (!story) return
    routeVersion++
    host.dismissChrome()
    openStory(card, story, opener ?? document.activeElement)
  }

  async function clearFiltersIfHidden(target: HTMLElement, page: HTMLElement): Promise<void> {
    if (target === page) return
    let hiddenByFilter = false
    for (let node: HTMLElement | null = target; node && node !== page; node = node.parentElement) {
      if (node.hidden) hiddenByFilter = true
    }
    if (!hiddenByFilter) return
    window.dispatchEvent(new CustomEvent(CLEAR_STORY_FILTERS_EVENT))
    await host.setView(host.getView() as ViewId)
  }

  async function route(hash: string = location.hash, focus = true): Promise<void> {
    const version = ++routeVersion
    const target = targetForHash(hash)
    if (!target) return

    const page = target.closest<HTMLElement>(".page-view")
    const view = page?.dataset.view
    if (!page || !view || !isViewId(view)) return

    const card = storyCardOf(target)

    if (isStoryOpen() && !card) {
      await closeStory({ restoreFocus: false })
      if (version !== routeVersion) return
    }

    await host.setView(view)
    if (version !== routeVersion) return

    await clearFiltersIfHidden(target, page)
    if (version !== routeVersion) return

    if (card) {
      card.scrollIntoView({ block: "center", behavior: "instant" })
      showStory(card, card.querySelector("[data-open-story]"))
      return
    }

    for (let node: HTMLElement | null = target; node && node !== page; node = node.parentElement) {
      if (node instanceof HTMLDetailsElement) node.open = true
    }
    host.dismissChrome()

    requestAnimationFrame(() => {
      if (version !== routeVersion) return
      if (target === page) {
        window.scrollTo({ top: 0, behavior: "instant" })
      } else {
        target.scrollIntoView({ block: "start", behavior: prefersReducedMotion() ? "instant" : "smooth" })
      }
      if (focus) focusTarget(target, page)
      if (target !== page) spotlight(target)
    })
  }

  function go(hash: string): void {
    const card = storyCardOf(targetForHash(hash))
    if (card) {
      showStory(card)
      return
    }
    if (location.hash !== hash) history.pushState(null, "", hash)
    void route(hash)
  }

  function onDocumentClick(event: MouseEvent): void {
    const eventTarget = event.target as HTMLElement | null
    if (!eventTarget) return

    const opener = eventTarget.closest<HTMLElement>("[data-open-story]")
    if (opener) {
      const card = document.getElementById(opener.dataset.openStory ?? "")
      if (card) showStory(card, opener)
      return
    }

    const link = eventTarget.closest<HTMLAnchorElement>('a[href^="#"]')
    if (!link || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return

    const hash = link.getAttribute("href") ?? ""
    if (hash === "#main-content") {
      event.preventDefault()
      document.getElementById("main-content")?.focus()
      return
    }
    if (!targetForHash(hash)) return

    event.preventDefault()
    const searchDialog = document.getElementById("search-dialog") as HTMLDialogElement | null
    if (searchDialog?.open) searchDialog.close()
    go(hash)
  }

  function onStoryDismissed(): void {
    if (storyCardOf(targetForHash(location.hash))) {
      history.replaceState(null, "", `#${host.getView()}`)
    }
  }

  function start(): () => void {
    const onHistory = (): void => {
      void route()
    }
    document.addEventListener("click", onDocumentClick)
    window.addEventListener("hashchange", onHistory)
    window.addEventListener("popstate", onHistory)
    void route(location.hash || "#overview", false)

    return () => {
      document.removeEventListener("click", onDocumentClick)
      window.removeEventListener("hashchange", onHistory)
      window.removeEventListener("popstate", onHistory)
    }
  }

  return { route, go, onStoryDismissed, start }
}
