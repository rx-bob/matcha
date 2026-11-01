import { describe, expect, it } from "vitest"
import type { Plan } from "../../../src/plan"
import { buildFileIdMap } from "./fileTreeHelpers"
import { buildSearchIndex, filterSearch, highlightSegments, suggestedItems } from "./search"

const plan = {
  schemaVersion: 1,
  id: "demo",
  title: "Demo",
  sections: [{ id: "arch", title: "Architecture", items: [{ text: "Use sqlite" }] }],
  epics: [
    {
      id: "E1",
      title: "Core",
      summary: "Foundations",
      stories: [
        { id: "E1.S1", title: "Build parser", risk: "low", filesLikelyTouched: ["src/a.zig"] },
      ],
    },
  ],
  changedFiles: [
    {
      root: {
        name: "src",
        type: "folder",
        children: [{ name: "a.zig", type: "file", status: "new", stories: ["E1.S1"] }],
      },
    },
  ],
} as unknown as Plan

const index = buildSearchIndex(plan, buildFileIdMap(plan.changedFiles))

describe("search index", () => {
  it("indexes stories, epics, sections, files and pages", () => {
    const kinds = new Set(index.map((item) => item.kind))
    expect([...kinds].sort()).toEqual(["epic", "file", "page", "section", "story"])
    expect(index.find((item) => item.kind === "file")).toMatchObject({ id: "file-0", title: "src/a.zig" })
  })

  it("requires every word to match", () => {
    expect(filterSearch(index, "parser low").map((i) => i.id)).toEqual(["E1.S1"])
    expect(filterSearch(index, "parser nonsense")).toEqual([])
    expect(filterSearch(index, "   ")).toEqual([])
  })

  it("finds files by path", () => {
    expect(filterSearch(index, "a.zig").some((i) => i.kind === "file")).toBe(true)
  })

  it("suggests story, epics and pages with no query", () => {
    expect(suggestedItems(index).map((i) => i.id)).toEqual(["E1.S1", "E1", "order", "criteria"])
  })
})

describe("highlightSegments", () => {
  it("marks every word occurrence case-insensitively", () => {
    expect(highlightSegments("Build Parser build", "build")).toEqual([
      { text: "Build", match: true },
      { text: " Parser ", match: false },
      { text: "build", match: true },
    ])
  })

  it("merges overlapping matches", () => {
    expect(highlightSegments("abcd", "ab bc")).toEqual([{ text: "abc", match: true }, { text: "d", match: false }])
  })

  it("returns plain text without a query", () => {
    expect(highlightSegments("abc", "")).toEqual([{ text: "abc", match: false }])
  })
})
