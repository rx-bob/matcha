import { describe, it, expect, vi, beforeEach } from "vitest"
import { copyText, initClipboardDelegation } from "./clipboard"

describe("clipboard", () => {
  let mockToast: { textContent: string; hidden: boolean }
  let eventListeners: Record<string, ((event: any) => void)[]>
  let writeTextMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    vi.restoreAllMocks()
    eventListeners = {}
    mockToast = { textContent: "", hidden: true }
    writeTextMock = vi.fn().mockResolvedValue(undefined)

    const mockDocument = {
      getElementById: (id: string) => {
        if (id === "toast") return mockToast
        return null
      },
      addEventListener: (type: string, handler: (event: any) => void) => {
        if (!eventListeners[type]) eventListeners[type] = []
        eventListeners[type].push(handler)
      },
      removeEventListener: (type: string, handler: (event: any) => void) => {
        if (!eventListeners[type]) return
        eventListeners[type] = eventListeners[type].filter((h) => h !== handler)
      },
      body: {
        appendChild: () => {},
      },
      createElement: () => ({
        style: {},
        value: "",
        focus: () => {},
        select: () => {},
        remove: () => {},
      }),
    }

    Object.defineProperty(globalThis, "document", {
      value: mockDocument,
      configurable: true,
      writable: true,
    })
    Object.defineProperty(globalThis, "window", {
      value: { isSecureContext: true },
      configurable: true,
      writable: true,
    })
    Object.defineProperty(globalThis, "navigator", {
      value: {
        clipboard: {
          writeText: writeTextMock,
        },
      },
      configurable: true,
      writable: true,
    })
  })

  it("copies text via navigator.clipboard and shows toast", async () => {
    await copyText("/my/path/file.goose", "Local reference path copied")

    expect(writeTextMock).toHaveBeenCalledWith("/my/path/file.goose")
    expect(mockToast.textContent).toBe("Local reference path copied")
    expect(mockToast.hidden).toBe(false)
  })

  it("places the legacy copy input inside the active modal", async () => {
    writeTextMock.mockRejectedValue(new Error("denied"))
    const appendChild = vi.fn()
    const closest = vi.fn().mockReturnValue({ appendChild })
    Object.assign(document, {
      activeElement: { closest, isConnected: false },
      execCommand: vi.fn().mockReturnValue(true),
    })
    await copyText("/modal/reference")
    expect(closest).toHaveBeenCalledWith("dialog[open]")
    expect(appendChild).toHaveBeenCalled()
    expect(document.execCommand).toHaveBeenCalledWith("copy")
    expect(mockToast.hidden).toBe(false)
  })

  it("handles delegated click on [data-copy-path]", async () => {
    const cleanup = initClipboardDelegation()

    const clickListeners = eventListeners["click"] ?? []
    expect(clickListeners.length).toBeGreaterThan(0)

    const fakeEvent = {
      target: {
        closest: (selector: string) => {
          if (selector === "[data-copy-path]") {
            return {
              dataset: { copyPath: "/my/path/file.goose" },
            }
          }
          return null
        },
      },
      preventDefault: vi.fn(),
    }

    clickListeners[0](fakeEvent)
    expect(fakeEvent.preventDefault).toHaveBeenCalled()
    expect(writeTextMock).toHaveBeenCalledWith("/my/path/file.goose")

    cleanup()
  })

  it("handles delegated click on [data-copy-code]", async () => {
    const cleanup = initClipboardDelegation()

    const clickListeners = eventListeners["click"] ?? []
    expect(clickListeners.length).toBeGreaterThan(0)

    const fakeEvent = {
      target: {
        closest: (selector: string) => {
          if (selector === "[data-copy-code]") {
            return {
              closest: (sel: string) => {
                if (sel === ".code-example") {
                  return {
                    querySelector: (s: string) => {
                      if (s === "pre") return { textContent: "fn hello() {}" }
                      return null
                    },
                  }
                }
                return null
              },
            }
          }
          return null
        },
      },
      preventDefault: vi.fn(),
    }

    clickListeners[0](fakeEvent)
    expect(fakeEvent.preventDefault).toHaveBeenCalled()
    expect(writeTextMock).toHaveBeenCalledWith("fn hello() {}")

    cleanup()
  })
})
