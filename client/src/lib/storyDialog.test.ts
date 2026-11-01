import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { Story } from "../../../src/plan.ts"
import { closeStory, isStoryOpen, openStory, openStoryId } from "./storyDialog"

class FakeElement {
  id = ""
  hidden = false
  className = ""
  textContent = ""
  scrollTop = 0
  dataset: Record<string, string> = {}
  children: FakeElement[] = []
  style: Record<string, string> = {}
  isConnected = true
  open = false
  focused = 0
  attributes = new Set<string>()
  classes = new Set<string>()
  classList = {
    add: (name: string) => this.classes.add(name),
    remove: (name: string) => this.classes.delete(name),
    contains: (name: string) => this.classes.has(name),
  }

  constructor(id = "") {
    this.id = id
  }

  focus(): void {
    this.focused++
  }
  getClientRects(): number[] {
    return [1]
  }
  showModal(): void {
    this.open = true
  }
  close(): void {
    this.open = false
  }
  replaceChildren(...nodes: FakeElement[]): void {
    this.children = nodes
  }
  removeAttribute(name: string): void {
    this.attributes.delete(name)
  }
  querySelectorAll(): FakeElement[] {
    return []
  }
}

class FakeBody extends FakeElement {
  cloneNode(): FakeBody {
    return new FakeBody()
  }
}

class FakeCard extends FakeElement {
  body = new FakeBody()
  querySelector(selector: string): FakeBody | null {
    return selector === ".story-body" ? this.body : null
  }
}

const story = (id: string, risk?: Story["risk"]): Story => ({ id, title: `Title ${id}`, risk })

describe("storyDialog", () => {
  let elements: Record<string, FakeElement>

  beforeEach(() => {
    elements = {}
    for (const id of [
      "story-dialog",
      "story-dialog-content",
      "story-dialog-title",
      "story-dialog-id",
      "story-dialog-risk",
      "story-dialog-feedback",
    ]) {
      elements[id] = new FakeElement(id)
    }
    const body = new FakeElement()
    Object.defineProperty(globalThis, "document", {
      value: { getElementById: (id: string) => elements[id] ?? null, body, activeElement: null },
      configurable: true,
      writable: true,
    })
    Object.defineProperty(globalThis, "matchMedia", {
      value: () => ({ matches: true }),
      configurable: true,
      writable: true,
    })
  })

  afterEach(async () => {
    await closeStory({ immediate: true })
    vi.restoreAllMocks()
  })

  it("opens with story metadata and locks body scroll", () => {
    openStory(new FakeCard() as never, story("E1.S1", "high"), null)

    expect(isStoryOpen()).toBe(true)
    expect(openStoryId()).toBe("E1.S1")
    expect(elements["story-dialog-id"].textContent).toBe("E1.S1")
    expect(elements["story-dialog-title"].textContent).toBe("Title E1.S1")
    expect(elements["story-dialog-risk"].textContent).toBe("High risk")
    expect(elements["story-dialog-risk"].className).toBe("risk-badge high")
    expect(elements["story-dialog"].classList.contains("is-visible")).toBe(true)
    expect(document.body.style.overflow).toBe("hidden")
    expect(elements["story-dialog-content"].children).toHaveLength(1)
  })

  it("defaults the risk badge to medium", () => {
    openStory(new FakeCard() as never, story("E1.S2"), null)
    expect(elements["story-dialog-risk"].textContent).toBe("Medium risk")
  })

  it("swaps content in place for story-to-story navigation and keeps the original opener", async () => {
    const opener = new FakeElement()
    openStory(new FakeCard() as never, story("E1.S1"), opener as never)
    openStory(new FakeCard() as never, story("E1.S2"), new FakeElement() as never)

    expect(openStoryId()).toBe("E1.S2")
    expect(elements["story-dialog-title"].textContent).toBe("Title E1.S2")

    await closeStory()
    expect(opener.focused).toBe(1)
  })

  it("closes, clears content, unlocks scroll and restores focus to the opener", async () => {
    const opener = new FakeElement()
    openStory(new FakeCard() as never, story("E1.S1"), opener as never)

    await expect(closeStory()).resolves.toBe(true)

    expect(isStoryOpen()).toBe(false)
    expect(openStoryId()).toBeNull()
    expect(elements["story-dialog-content"].children).toHaveLength(0)
    expect(elements["story-dialog"].dataset.story).toBeUndefined()
    expect(document.body.style.overflow).toBe("")
    expect(opener.focused).toBe(1)
  })

  it("skips focus restoration when requested", async () => {
    const opener = new FakeElement()
    openStory(new FakeCard() as never, story("E1.S1"), opener as never)

    await closeStory({ restoreFocus: false })

    expect(opener.focused).toBe(0)
  })

  it("resolves true when closing an already closed dialog", async () => {
    await expect(closeStory()).resolves.toBe(true)
  })
})
