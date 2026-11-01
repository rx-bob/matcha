import { describe, expect, it } from "vitest"
import { fileDomId, hashDomTargetId, isViewId, normalizeHashId } from "./ids"

describe("normalizeHashId", () => {
  it("defaults empty and malformed hashes to overview", () => {
    expect(normalizeHashId("")).toBe("overview")
    expect(normalizeHashId("#")).toBe("overview")
    expect(normalizeHashId("#%E0%A4%A")).toBe("overview")
  })

  it("keeps canonical view ids", () => {
    for (const id of ["overview", "epics", "files", "context", "order", "criteria"]) {
      expect(normalizeHashId(`#${id}`)).toBe(id)
    }
  })

  it("resolves legacy view aliases", () => {
    expect(normalizeHashId("#summary")).toBe("overview")
    expect(normalizeHashId("#changed-files")).toBe("files")
    expect(normalizeHashId("#sections")).toBe("context")
    expect(normalizeHashId("#recommended-order")).toBe("order")
    expect(normalizeHashId("#exit-criteria")).toBe("criteria")
  })

  it("resolves epic and story ids including legacy forms", () => {
    expect(normalizeHashId("#E2")).toBe("E2")
    expect(normalizeHashId("#epic-E1")).toBe("E1")
    expect(normalizeHashId("#E1.S2")).toBe("E1.S2")
    expect(normalizeHashId("#story-E1-S1")).toBe("E1.S1")
  })

  it("resolves section, file, and reference anchors", () => {
    expect(normalizeHashId("#section-architecture-decisions")).toBe("architecture-decisions")
    expect(normalizeHashId("#file-0")).toBe("file-0")
    expect(normalizeHashId("#reference-unit-api")).toBe("reference-unit-api")
  })
})

describe("hashDomTargetId", () => {
  it("maps views to their page element ids", () => {
    expect(hashDomTargetId("#epics")).toBe("view-epics")
    expect(hashDomTargetId("#exit-criteria")).toBe("view-criteria")
    expect(hashDomTargetId("")).toBe("view-overview")
  })

  it("passes through non-view targets", () => {
    expect(hashDomTargetId("#story-E3-S1")).toBe("E3.S1")
    expect(hashDomTargetId("#reference-unit-api")).toBe("reference-unit-api")
  })
})

describe("view and file ids", () => {
  it("identifies view ids", () => {
    expect(isViewId("files")).toBe(true)
    expect(isViewId("E1")).toBe(false)
  })

  it("formats file ids", () => {
    expect(fileDomId(0)).toBe("file-0")
  })
})
