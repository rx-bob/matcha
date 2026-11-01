import { describe, it, expect } from "vitest"
import type { Epic } from "../../../src/plan"
import { filterEpicsAndStories } from "./epicsHelpers"

describe("epicsHelpers", () => {
  const sampleEpics: Epic[] = [
    {
      id: "E1",
      title: "Epic One",
      stories: [
        {
          id: "E1.S1",
          title: "First story compiler contract",
          risk: "high",
        },
        {
          id: "E1.S2",
          title: "Second story assertions",
          risk: "medium",
        },
      ],
    },
    {
      id: "E2",
      title: "Epic Two",
      stories: [
        {
          id: "E2.S1",
          title: "Third story scanner",
          risk: "low",
        },
      ],
    },
  ]

  it("returns all visible when no filter is applied", () => {
    const state = filterEpicsAndStories(sampleEpics, "")
    expect(state.totalStories).toBe(3)
    expect(state.visibleStories).toBe(3)
    expect(state.epicVisibility["E1"]).toBe(true)
    expect(state.epicVisibility["E2"]).toBe(true)
    expect(state.storyVisibility["E1.S1"]).toBe(true)
    expect(state.storyVisibility["E1.S2"]).toBe(true)
    expect(state.storyVisibility["E2.S1"]).toBe(true)
  })

  it("filters by text query across fields", () => {
    const state = filterEpicsAndStories(sampleEpics, "compiler")
    expect(state.visibleStories).toBe(1)
    expect(state.storyVisibility["E1.S1"]).toBe(true)
    expect(state.storyVisibility["E1.S2"]).toBe(false)
    expect(state.storyVisibility["E2.S1"]).toBe(false)
    expect(state.epicVisibility["E1"]).toBe(true)
    expect(state.epicVisibility["E2"]).toBe(false)
  })

  it("returns no stories for unmatched search terms", () => {
    const state = filterEpicsAndStories(sampleEpics, "missing")
    expect(state.visibleStories).toBe(0)
    expect(state.epicVisibility["E1"]).toBe(false)
    expect(state.epicVisibility["E2"]).toBe(false)
  })

  it("requires every search word to match", () => {
    expect(filterEpicsAndStories(sampleEpics, "compiler contract").visibleStories).toBe(1)
    expect(filterEpicsAndStories(sampleEpics, "compiler scanner").visibleStories).toBe(0)
  })
})
