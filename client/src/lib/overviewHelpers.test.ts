import { describe, it, expect } from "vitest"
import {
  splitHeroTitle,
  countProposedFiles,
  getFirstStory,
  formatMetadataKey,
  resolveViewForHash,
} from "./overviewHelpers"
import type { Plan, FileTree } from "../../../src/plan"

describe("overviewHelpers", () => {
  describe("splitHeroTitle", () => {
    it("uses heroTitle object when provided", () => {
      const result = splitHeroTitle("Fallback Title", { lead: "First", accent: "release." })
      expect(result).toEqual({ lead: "First", accent: "release." })
    })

    it("splits heroTitle string into lead and last word accent", () => {
      const result = splitHeroTitle("Fallback", "Awesome New Release")
      expect(result).toEqual({ lead: "Awesome New", accent: "Release" })
    })

    it("strips project prefix from title when heroTitle is omitted", () => {
      const result = splitHeroTitle("goosetest: First-Release Implementation Plan", undefined, "goosetest")
      expect(result).toEqual({ lead: "First-Release Implementation", accent: "Plan" })
    })

    it("strips generic colon prefix when project does not match", () => {
      const result = splitHeroTitle("matcha: Work in Progress", undefined, "other")
      expect(result).toEqual({ lead: "Work in", accent: "Progress" })
    })

    it("handles single-word titles without accent", () => {
      const result = splitHeroTitle("SingleWord")
      expect(result).toEqual({ lead: "SingleWord", accent: "" })
    })
  })

  describe("countProposedFiles", () => {
    it("returns 0 for empty or missing files", () => {
      expect(countProposedFiles()).toBe(0)
      expect(countProposedFiles([])).toBe(0)
    })

    it("recursively counts only file nodes", () => {
      const tree: FileTree[] = [
        {
          root: {
            name: "root",
            type: "folder",
            children: [
              { name: "file1.ts", type: "file" },
              {
                name: "subfolder",
                type: "folder",
                children: [
                  { name: "file2.ts", type: "file" },
                  { name: "file3.ts", type: "file" },
                ],
              },
            ],
          },
        },
        {
          root: {
            name: "standalone.md",
            type: "file",
          },
        },
      ]
      expect(countProposedFiles(tree)).toBe(4)
    })
  })

  describe("getFirstStory", () => {
    const basePlan: Plan = {
      schemaVersion: 1,
      id: "test-plan",
      title: "Test Plan",
      epics: [
        {
          id: "E1",
          title: "Epic One",
          stories: [
            {
              id: "E1.S1",
              title: "First Story Title",
              details: ["This is sentence one. This is sentence two."],
            },
            {
              id: "E1.S2",
              title: "Second Story Title",
              description: "Description sentence. More info.",
            },
          ],
        },
      ],
      changedFiles: [],
    }

    it("prefers recommendedOrder[0] when present", () => {
      const plan: Plan = {
        ...basePlan,
        recommendedOrder: [{ ref: "E1.S2", reason: "Do second first" }],
      }
      const first = getFirstStory(plan)
      expect(first?.id).toBe("E1.S2")
      expect(first?.title).toBe("Second Story Title")
      expect(first?.summary).toBe("Description sentence.")
    })

    it("uses plan.firstStorySummary when present", () => {
      const plan: Plan = {
        ...basePlan,
        firstStorySummary: "Custom hero summary for the story.",
      }
      const first = getFirstStory(plan)
      expect(first?.id).toBe("E1.S1")
      expect(first?.summary).toBe("Custom hero summary for the story.")
    })

    it("falls back to first sentence of details[0] when firstStorySummary is absent", () => {
      const first = getFirstStory(basePlan)
      expect(first?.id).toBe("E1.S1")
      expect(first?.summary).toBe("This is sentence one.")
    })

    it("returns null if plan has no stories", () => {
      const emptyPlan: Plan = {
        schemaVersion: 1,
        id: "empty",
        title: "Empty",
        changedFiles: [],
      }
      expect(getFirstStory(emptyPlan)).toBeNull()
    })
  })

  describe("formatMetadataKey", () => {
    it("formats camelCase and snake_case keys into sentence case", () => {
      expect(formatMetadataKey("projectRoot")).toBe("Project root")
      expect(formatMetadataKey("planning_assumptions")).toBe("Planning assumptions")
      expect(formatMetadataKey("requestedOutputDirectory")).toBe("Requested output directory")
      expect(formatMetadataKey("canonicalPlan")).toBe("Canonical plan")
    })
  })

  describe("resolveViewForHash", () => {
    const plan: Plan = {
      schemaVersion: 1,
      id: "p1",
      title: "Plan",
      sections: [{ id: "scope-decisions", title: "Scope" }],
      changedFiles: [],
    }

    it("resolves primary view names", () => {
      expect(resolveViewForHash("#overview")).toBe("overview")
      expect(resolveViewForHash("context")).toBe("context")
      expect(resolveViewForHash("#criteria")).toBe("criteria")
    })

    it("resolves legacy aliases", () => {
      expect(resolveViewForHash("#sections")).toBe("context")
      expect(resolveViewForHash("#changed-files")).toBe("files")
      expect(resolveViewForHash("#recommended-order")).toBe("order")
      expect(resolveViewForHash("#exit-criteria")).toBe("criteria")
    })

    it("resolves section IDs to context", () => {
      expect(resolveViewForHash("#scope-decisions", plan)).toBe("context")
      expect(resolveViewForHash("#section-scope-decisions", plan)).toBe("context")
    })

    it("resolves epic and story IDs to epics", () => {
      expect(resolveViewForHash("#E1")).toBe("epics")
      expect(resolveViewForHash("#E1.S2")).toBe("epics")
      expect(resolveViewForHash("#epic-E2")).toBe("epics")
      expect(resolveViewForHash("#story-E1-S1")).toBe("epics")
    })
  })
})
