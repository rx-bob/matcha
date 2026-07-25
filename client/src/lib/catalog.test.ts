import { describe, it, expect } from "vitest"
import {
  artifactMatchesFilter,
  artifactMatchesSearch,
  basename,
  catalogsEqual,
  displayTitle,
  filterProjects,
  formatGeneratedAt,
  formatMtime,
  isEmptyCatalog,
  mtimeToMillis,
  normalizeSearch,
  parseCatalog,
  reducePoll,
  toArtifactDisplay,
  toProjectDisplays,
  totalArtifactCount,
  type Catalog,
  type CatalogArtifact,
  type ProjectDisplay,
  type TypeFilter,
} from "./catalog.ts"

function artifact(overrides: Partial<CatalogArtifact> = {}): CatalogArtifact {
  return {
    relPath: "matcha/plan.html",
    url: "/artifacts/matcha/plan.html",
    kind: "plan",
    group: "matcha",
    size: 1234,
    mtime: 1_753_440_000_000_000_000,
    title: "Rendered Plan",
    ...overrides,
  }
}

describe("basename", () => {
  it("returns the final path segment", () => {
    expect(basename("a/b/c.html")).toBe("c.html")
    expect(basename("plan.html")).toBe("plan.html")
  })
  it("handles trailing slash", () => {
    expect(basename("a/b/")).toBe("")
  })
})

describe("displayTitle", () => {
  it("uses the embedded title when present and non-empty", () => {
    expect(displayTitle(artifact({ title: "My Plan" }))).toBe("My Plan")
  })
  it("falls back to filename when title is missing", () => {
    expect(displayTitle(artifact({ title: undefined }))).toBe("plan.html")
  })
  it("falls back to filename when title is blank", () => {
    expect(displayTitle(artifact({ title: "   " }))).toBe("plan.html")
  })
})

describe("mtimeToMillis", () => {
  it("converts nanoseconds to milliseconds", () => {
    expect(mtimeToMillis(1_000_000_000)).toBe(1000)
  })
  it("returns null for missing or invalid values", () => {
    expect(mtimeToMillis(0)).toBeNull()
    expect(mtimeToMillis(-1)).toBeNull()
    expect(mtimeToMillis(Number.NaN)).toBeNull()
    expect(mtimeToMillis(Number.POSITIVE_INFINITY)).toBeNull()
  })
  it("handles large nanosecond values safely via BigInt path", () => {
    // 2026-07 in ns ≈ 1.78e18, exceeds MAX_SAFE_INTEGER
    const ns = 1_753_440_000_000_000_000
    const ms = mtimeToMillis(ns)
    expect(ms).not.toBeNull()
    expect(typeof ms).toBe("number")
    expect(ms).toBe(1_753_440_000_000)
  })
})

describe("formatMtime", () => {
  it("formats a valid nanosecond mtime as a local date string", () => {
    const formatted = formatMtime(1_753_440_000_000_000_000)
    expect(formatted).not.toBe("")
    expect(formatted.length).toBeGreaterThan(0)
    // Should contain a 4-digit year.
    expect(/\d{4}/.test(formatted)).toBe(true)
  })
  it("returns an empty string for invalid values", () => {
    expect(formatMtime(0)).toBe("")
    expect(formatMtime(Number.NaN)).toBe("")
  })
})

describe("formatGeneratedAt", () => {
  it("formats a valid ISO-8601 string", () => {
    const formatted = formatGeneratedAt("2026-07-24T22:14:13+02:00")
    expect(formatted).not.toBe("")
    expect(/\d{4}/.test(formatted)).toBe(true)
  })
  it("returns an empty string when the value is missing or invalid", () => {
    expect(formatGeneratedAt(undefined)).toBe("")
    expect(formatGeneratedAt("not a date")).toBe("")
  })
})

describe("toArtifactDisplay", () => {
  it("transforms a complete artifact into a display model", () => {
    const display = toArtifactDisplay(
      artifact({
        kind: "map",
        title: "My Map",
        status: "draft",
        generatedAt: "2026-07-24T22:14:13Z",
        diagramKind: "class",
        relPath: "matcha/sub/map.html",
      }),
    )
    expect(display.kind).toBe("map")
    expect(display.title).toBe("My Map")
    expect(display.status).toBe("draft")
    expect(display.generatedAt).not.toBe("")
    expect(display.diagramKind).toBe("class")
    expect(display.filename).toBe("map.html")
    expect(display.mtime).not.toBe("")
    expect(display.size).toBe(1234)
  })
  it("coerces missing optional fields to empty strings", () => {
    const display = toArtifactDisplay(
      artifact({
        title: undefined,
        status: undefined,
        generatedAt: undefined,
        diagramKind: undefined,
      }),
    )
    expect(display.title).toBe("plan.html")
    expect(display.status).toBe("")
    expect(display.generatedAt).toBe("")
    expect(display.diagramKind).toBe("")
    // No broken labels.
    expect(display.title).not.toContain("undefined")
    expect(display.status).not.toContain("null")
  })
})

describe("toProjectDisplays", () => {
  it("transforms a populated catalog preserving server ordering", () => {
    const catalog: Catalog = {
      projects: [
        {
          name: "alpha",
          artifacts: [
            artifact({ relPath: "alpha/plan.html", title: "Alpha Plan", kind: "plan" }),
            artifact({ relPath: "alpha/map.html", title: "Alpha Map", kind: "map" }),
          ],
        },
        {
          name: "beta",
          artifacts: [artifact({ relPath: "beta/plan.html", title: "Beta Plan" })],
        },
      ],
      warnings: [],
    }
    const projects = toProjectDisplays(catalog)
    expect(projects).toHaveLength(2)
    expect(projects[0].name).toBe("alpha")
    expect(projects[0].artifacts).toHaveLength(2)
    expect(projects[0].artifacts[0].title).toBe("Alpha Plan")
    expect(projects[0].artifacts[1].title).toBe("Alpha Map")
    expect(projects[1].name).toBe("beta")
    expect(projects[1].artifacts[0].title).toBe("Beta Plan")
  })
  it("preserves projects with zero artifacts", () => {
    const catalog: Catalog = {
      projects: [{ name: "empty", artifacts: [] }],
      warnings: [],
    }
    const projects = toProjectDisplays(catalog)
    expect(projects).toHaveLength(1)
    expect(projects[0].artifacts).toHaveLength(0)
  })
})

describe("totalArtifactCount and isEmptyCatalog", () => {
  it("counts artifacts across all projects", () => {
    const catalog: Catalog = {
      projects: [
        { name: "a", artifacts: [artifact()] },
        { name: "b", artifacts: [artifact(), artifact()] },
      ],
      warnings: [],
    }
    expect(totalArtifactCount(catalog)).toBe(3)
    expect(isEmptyCatalog(catalog)).toBe(false)
  })
  it("treats the synthetic Ungrouped placeholder as empty", () => {
    const catalog: Catalog = {
      projects: [{ name: "Ungrouped", artifacts: [] }],
      warnings: [],
    }
    expect(totalArtifactCount(catalog)).toBe(0)
    expect(isEmptyCatalog(catalog)).toBe(true)
  })
  it("treats a truly empty projects array as empty", () => {
    const catalog: Catalog = { projects: [], warnings: [] }
    expect(isEmptyCatalog(catalog)).toBe(true)
  })
})

describe("parseCatalog", () => {
  it("parses a complete catalog payload", () => {
    const json = {
      projects: [
        {
          name: "matcha",
          artifacts: [
            {
              relPath: "matcha/plan.html",
              url: "/artifacts/matcha/plan.html",
              kind: "plan",
              group: "matcha",
              size: 100,
              mtime: 1_753_440_000_000_000_000,
              title: "Plan",
              status: "planned",
              generatedAt: "2026-07-24T22:14:13Z",
            },
            {
              relPath: "matcha/map.html",
              url: "/artifacts/matcha/map.html",
              kind: "map",
              group: "matcha",
              size: 200,
              mtime: 1_753_440_000_000_000_000,
              title: "Map",
              diagramKind: "class",
            },
          ],
        },
      ],
      warnings: [{ relPath: "bad.html", reason: "malformed" }],
    }
    const catalog = parseCatalog(json)
    expect(catalog.projects).toHaveLength(1)
    expect(catalog.projects[0].artifacts).toHaveLength(2)
    expect(catalog.projects[0].artifacts[0].kind).toBe("plan")
    expect(catalog.projects[0].artifacts[1].kind).toBe("map")
    expect(catalog.projects[0].artifacts[1].diagramKind).toBe("class")
    expect(catalog.warnings).toHaveLength(1)
  })
  it("defaults missing arrays to empty", () => {
    const catalog = parseCatalog({})
    expect(catalog.projects).toEqual([])
    expect(catalog.warnings).toEqual([])
  })
  it("defaults missing artifact optional fields", () => {
    const json = {
      projects: [
        {
          name: "x",
          artifacts: [{ relPath: "x.html", url: "/artifacts/x.html", kind: "plan", group: "x", size: 1, mtime: 1 }],
        },
      ],
      warnings: [],
    }
    const catalog = parseCatalog(json)
    const a = catalog.projects[0].artifacts[0]
    expect(a.title).toBeUndefined()
    expect(a.status).toBeUndefined()
    expect(a.generatedAt).toBeUndefined()
    expect(a.diagramKind).toBeUndefined()
  })
  it("coerces an unknown kind to plan", () => {
    const json = {
      projects: [
        {
          name: "x",
          artifacts: [{ relPath: "x.html", url: "/artifacts/x.html", kind: "bogus", group: "x", size: 1, mtime: 1 }],
        },
      ],
      warnings: [],
    }
    expect(parseCatalog(json).projects[0].artifacts[0].kind).toBe("plan")
  })
  it("handles non-object input gracefully", () => {
    expect(parseCatalog(null)).toEqual({ projects: [], warnings: [] })
    expect(parseCatalog("not json")).toEqual({ projects: [], warnings: [] })
    expect(parseCatalog(undefined)).toEqual({ projects: [], warnings: [] })
  })
})

describe("deterministic ordering", () => {
  it("does not reorder artifacts already sorted by the server", () => {
    const catalog: Catalog = {
      projects: [
        {
          name: "p",
          artifacts: [
            artifact({ relPath: "p/a.html", title: "A" }),
            artifact({ relPath: "p/b.html", title: "B", kind: "map" }),
            artifact({ relPath: "p/c.html", title: "C" }),
          ],
        },
      ],
      warnings: [],
    }
    const display = toProjectDisplays(catalog)
    expect(display[0].artifacts.map((a) => a.title)).toEqual(["A", "B", "C"])
  })
})

function projectDisplays(overrides: { name?: string; artifacts: Partial<CatalogArtifact>[] }): ProjectDisplay[] {
  return [
    {
      name: overrides.name ?? "p",
      artifacts: overrides.artifacts.map((a) =>
        toArtifactDisplay(artifact({ group: overrides.name ?? "p", ...a })),
      ),
    },
  ]
}

describe("normalizeSearch", () => {
  it("lowercases and collapses whitespace", () => {
    expect(normalizeSearch("  Hello   World  ")).toBe("hello world")
  })
  it("returns empty for blank or empty input", () => {
    expect(normalizeSearch("")).toBe("")
    expect(normalizeSearch("   ")).toBe("")
  })
  it("treats nullish input as empty", () => {
    expect(normalizeSearch(null as unknown as string)).toBe("")
    expect(normalizeSearch(undefined as unknown as string)).toBe("")
  })
})

describe("artifactMatchesSearch", () => {
  const display = toArtifactDisplay(
    artifact({ relPath: "matcha/plan.html", title: "Rendered Plan" }),
  )
  it("matches the project name", () => {
    expect(artifactMatchesSearch(display, "matcha", "matcha")).toBe(true)
  })
  it("matches the title", () => {
    expect(artifactMatchesSearch(display, "matcha", "rendered")).toBe(true)
  })
  it("matches the relative path", () => {
    expect(artifactMatchesSearch(display, "matcha", "plan.html")).toBe(true)
  })
  it("matches case-insensitively", () => {
    expect(artifactMatchesSearch(display, "matcha", normalizeSearch("RENDERED PLAN"))).toBe(true)
  })
  it("returns true for an empty query", () => {
    expect(artifactMatchesSearch(display, "matcha", "")).toBe(true)
  })
  it("returns false when no field matches", () => {
    expect(artifactMatchesSearch(display, "matcha", "nonexistent")).toBe(false)
  })
})

describe("artifactMatchesFilter", () => {
  const plan = toArtifactDisplay(artifact({ kind: "plan" }))
  const map = toArtifactDisplay(artifact({ kind: "map" }))
  it("all passes every kind", () => {
    expect(artifactMatchesFilter(plan, "all")).toBe(true)
    expect(artifactMatchesFilter(map, "all")).toBe(true)
  })
  it("plan passes only plans", () => {
    expect(artifactMatchesFilter(plan, "plan")).toBe(true)
    expect(artifactMatchesFilter(map, "plan")).toBe(false)
  })
  it("map passes only maps", () => {
    expect(artifactMatchesFilter(plan, "map")).toBe(false)
    expect(artifactMatchesFilter(map, "map")).toBe(true)
  })
})

describe("filterProjects", () => {
  const projects: ProjectDisplay[] = [
    {
      name: "alpha",
      artifacts: [
        toArtifactDisplay(artifact({ relPath: "alpha/plan.html", title: "Alpha Plan", kind: "plan" })),
        toArtifactDisplay(artifact({ relPath: "alpha/map.html", title: "Alpha Map", kind: "map" })),
      ],
    },
    {
      name: "beta",
      artifacts: [
        toArtifactDisplay(artifact({ relPath: "beta/plan.html", title: "Beta Plan", kind: "plan" })),
      ],
    },
  ]

  it("returns non-empty projects unchanged when no search and all filter", () => {
    const filtered = filterProjects(projects, "", "all")
    expect(filtered).toHaveLength(2)
    expect(filtered[0].artifacts).toHaveLength(2)
    expect(filtered[1].artifacts).toHaveLength(1)
  })
  it("filters by type only", () => {
    const filtered = filterProjects(projects, "", "map")
    expect(filtered).toHaveLength(1)
    expect(filtered[0].name).toBe("alpha")
    expect(filtered[0].artifacts).toHaveLength(1)
    expect(filtered[0].artifacts[0].kind).toBe("map")
  })
  it("filters by search query across project, title, and path", () => {
    expect(filterProjects(projects, "beta", "all")).toHaveLength(1)
    expect(filterProjects(projects, "alpha plan", "all")[0].artifacts).toHaveLength(1)
    expect(filterProjects(projects, "map.html", "all")[0].artifacts).toHaveLength(1)
  })
  it("combines search and type filter", () => {
    const filtered = filterProjects(projects, "alpha", "map")
    expect(filtered).toHaveLength(1)
    expect(filtered[0].artifacts).toHaveLength(1)
    expect(filtered[0].artifacts[0].kind).toBe("map")
  })
  it("drops projects whose artifacts all fail the filters", () => {
    expect(filterProjects(projects, "gamma", "all")).toHaveLength(0)
    expect(filterProjects(projects, "", "map")).toHaveLength(1)
  })
  it("preserves artifact ordering within surviving projects", () => {
    const filtered = filterProjects(projects, "alpha", "all")
    expect(filtered[0].artifacts.map((a) => a.title)).toEqual(["Alpha Plan", "Alpha Map"])
  })
  it("filter state survives a catalog replacement (filter is pure)", () => {
    const filter: TypeFilter = "map"
    const first = filterProjects(projects, "", filter)
    const second = filterProjects(projects, "", filter)
    expect(second).toEqual(first)
  })
})

describe("catalogsEqual", () => {
  const a: Catalog = {
    projects: [
      {
        name: "p",
        artifacts: [artifact({ relPath: "p/plan.html", title: "P" })],
      },
    ],
    warnings: [],
  }
  it("returns true for identical references", () => {
    expect(catalogsEqual(a, a)).toBe(true)
  })
  it("returns true for value-equal catalogs", () => {
    const b: Catalog = {
      projects: [
        {
          name: "p",
          artifacts: [artifact({ relPath: "p/plan.html", title: "P" })],
        },
      ],
      warnings: [],
    }
    expect(catalogsEqual(a, b)).toBe(true)
  })
  it("returns false when project counts differ", () => {
    const b: Catalog = { ...a, projects: [...a.projects, { name: "q", artifacts: [] }] }
    expect(catalogsEqual(a, b)).toBe(false)
  })
  it("returns false when artifact counts differ", () => {
    const b: Catalog = {
      projects: [{ name: "p", artifacts: [...a.projects[0].artifacts, artifact()] }],
      warnings: [],
    }
    expect(catalogsEqual(a, b)).toBe(false)
  })
  it("returns false when mtime changes", () => {
    const b: Catalog = {
      projects: [
        {
          name: "p",
          artifacts: [artifact({ relPath: "p/plan.html", title: "P", mtime: 999 })],
        },
      ],
      warnings: [],
    }
    expect(catalogsEqual(a, b)).toBe(false)
  })
  it("returns false when optional metadata changes", () => {
    const base = artifact({ relPath: "p/plan.html", title: "P" })
    const a2: Catalog = { projects: [{ name: "p", artifacts: [base] }], warnings: [] }
    const b: Catalog = {
      projects: [{ name: "p", artifacts: [{ ...base, status: "planned" }] }],
      warnings: [],
    }
    expect(catalogsEqual(a2, b)).toBe(false)
  })
  it("returns false when warnings differ", () => {
    const b: Catalog = { ...a, warnings: [{ relPath: "x.html", reason: "bad" }] }
    expect(catalogsEqual(a, b)).toBe(false)
  })
})

describe("reducePoll", () => {
  it("start triggers an immediate fetch", () => {
    const result = reducePoll({ phase: "idle" }, { type: "start" })
    expect(result.state.phase).toBe("fetching")
    expect(result.effect.kind).toBe("fetch")
  })
  it("fetch-succeeded schedules the next poll", () => {
    const result = reducePoll(
      { phase: "fetching" },
      { type: "fetch-succeeded", catalog: { projects: [], warnings: [] }, unchanged: false },
    )
    expect(result.state.phase).toBe("fetching")
    expect(result.effect.kind).toBe("schedule-next")
  })
  it("fetch-failed schedules the next poll (keeps prior catalog)", () => {
    const result = reducePoll({ phase: "fetching" }, { type: "fetch-failed" })
    expect(result.state.phase).toBe("fetching")
    expect(result.effect.kind).toBe("schedule-next")
  })
  it("stop returns to idle and performs no work", () => {
    const result = reducePoll({ phase: "fetching" }, { type: "stop" })
    expect(result.state.phase).toBe("idle")
    expect(result.effect.kind).toBe("none")
  })
  it("visibility hidden from fetching pauses the loop", () => {
    const result = reducePoll({ phase: "fetching" }, { type: "visibility", hidden: true })
    expect(result.state.phase).toBe("paused")
    expect(result.effect.kind).toBe("pause")
  })
  it("visibility visible from paused resumes with a refresh", () => {
    const result = reducePoll({ phase: "paused" }, { type: "visibility", hidden: false })
    expect(result.state.phase).toBe("fetching")
    expect(result.effect.kind).toBe("resume")
  })
  it("visibility hidden while already paused does nothing", () => {
    const result = reducePoll({ phase: "paused" }, { type: "visibility", hidden: true })
    expect(result.state.phase).toBe("paused")
    expect(result.effect.kind).toBe("none")
  })
  it("interval-elapsed while fetching triggers another fetch", () => {
    const result = reducePoll({ phase: "fetching" }, { type: "interval-elapsed" })
    expect(result.state.phase).toBe("fetching")
    expect(result.effect.kind).toBe("fetch")
  })
  it("interval-elapsed while idle does nothing", () => {
    const result = reducePoll({ phase: "idle" }, { type: "interval-elapsed" })
    expect(result.state.phase).toBe("idle")
    expect(result.effect.kind).toBe("none")
  })
  it("interval-elapsed while paused does nothing", () => {
    const result = reducePoll({ phase: "paused" }, { type: "interval-elapsed" })
    expect(result.state.phase).toBe("paused")
    expect(result.effect.kind).toBe("none")
  })
  it("stop after visibility hidden returns to idle", () => {
    const result = reducePoll({ phase: "paused" }, { type: "stop" })
    expect(result.state.phase).toBe("idle")
    expect(result.effect.kind).toBe("none")
  })
})
