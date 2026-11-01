import { describe, it, expect } from "vitest"
import type { Epic } from "../../../src/plan"
import { extractAvailableRisks, filterEpicsAndStories } from "./epicsHelpers"

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

  it("extracts unique available risks in priority order", () => {
    const risks = extractAvailableRisks(sampleEpics)
    expect(risks).toEqual(["high", "medium", "low"])
  })

  it("returns all visible when no filter is applied", () => {
    const state = filterEpicsAndStories(sampleEpics, "", "all")
    expect(state.totalStories).toBe(3)
    expect(state.visibleStories).toBe(3)
    expect(state.epicVisibility["E1"]).toBe(true)
    expect(state.epicVisibility["E2"]).toBe(true)
    expect(state.storyVisibility["E1.S1"]).toBe(true)
    expect(state.storyVisibility["E1.S2"]).toBe(true)
    expect(state.storyVisibility["E2.S1"]).toBe(true)
  })

  it("filters by text query across fields", () => {
    const state = filterEpicsAndStories(sampleEpics, "compiler", "all")
    expect(state.visibleStories).toBe(1)
    expect(state.storyVisibility["E1.S1"]).toBe(true)
    expect(state.storyVisibility["E1.S2"]).toBe(false)
    expect(state.storyVisibility["E2.S1"]).toBe(false)
    expect(state.epicVisibility["E1"]).toBe(true)
    expect(state.epicVisibility["E2"]).toBe(false)
  })

  it("filters by risk level", () => {
    const state = filterEpicsAndStories(sampleEpics, "", "high")
    expect(state.visibleStories).toBe(1)
    expect(state.storyVisibility["E1.S1"]).toBe(true)
    expect(state.storyVisibility["E1.S2"]).toBe(false)
    expect(state.storyVisibility["E2.S1"]).toBe(false)
    expect(state.epicVisibility["E1"]).toBe(true)
    expect(state.epicVisibility["E2"]).toBe(false)
  })

  it("combines text query and risk level filter", () => {
    const state = filterEpicsAndStories(sampleEpics, "assertions", "high")
    expect(state.visibleStories).toBe(0)
    expect(state.epicVisibility["E1"]).toBe(false)
    expect(state.epicVisibility["E2"]).toBe(false)
  })
})
