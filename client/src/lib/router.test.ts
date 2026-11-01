import { afterEach, expect, it, vi } from "vitest"
import { createRouter } from "./router"
import { openStory } from "./storyDialog"
import type { Plan } from "../../../src/plan"
vi.mock("./storyDialog", () => ({ closeStory: vi.fn(), isStoryOpen: () => false, openStory: vi.fn() }))
afterEach(() => { vi.unstubAllGlobals(); vi.clearAllMocks() })
it("story links switch view and enter browser history before opening", async () => {
  const page = { dataset: { view: "epics" } }
  const card = {
    dataset: { story: "E1.S1" }, parentElement: page,
    closest: (selector: string): unknown => selector === ".page-view" ? page : card,
    querySelector: () => null, scrollIntoView: vi.fn(),
  }
  const pushState = vi.fn()
  vi.stubGlobal("location", { hash: "#overview" })
  vi.stubGlobal("history", { pushState })
  vi.stubGlobal("document", { getElementById: () => card, activeElement: null })
  const setView = vi.fn().mockResolvedValue(undefined)
  const router = createRouter({
    plan: { epics: [{ stories: [{ id: "E1.S1" }] }] } as Plan,
    getView: () => "overview", setView, dismissChrome: vi.fn(),
  })
  router.go("#E1.S1")
  await vi.waitFor(() => expect(openStory).toHaveBeenCalled())
  expect(pushState).toHaveBeenCalledWith(null, "", "#E1.S1")
  expect(setView).toHaveBeenCalledWith("epics")
})
