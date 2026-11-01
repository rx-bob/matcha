import type { JsonValue, PlanSection } from "../../../src/plan.ts"

export function sectionDomId(id: string): string {
  return "section-" + id
}

export function epicDomId(epicId: string): string {
  return "epic-" + epicId
}

export function storyDomId(storyId: string): string {
  return "story-" + storyId.replaceAll(".", "-")
}

export function formatJsonValue(value: JsonValue): string {
  if (Array.isArray(value)) {
    return value.join(", ")
  }

  if (value !== null && typeof value === "object") {
    return JSON.stringify(value)
  }

  if (value !== undefined && value !== null) {
    return String(value)
  }

  return ""
}

export function tableColumns(_section: PlanSection): string[] {
  return []
}

export function scrollToId(id: string): void {
  const target = document.getElementById(id)

  if (target) {
    target.scrollIntoView({ behavior: "smooth", block: "start" })
  }
}

export const VIEW_IDS = ["overview", "epics", "files", "context", "order", "criteria"] as const

export type ViewId = (typeof VIEW_IDS)[number]

export const VIEW_TITLES: Record<ViewId, string> = {
  overview: "Overview",
  epics: "Implementation",
  files: "Project files",
  context: "Architecture & decisions",
  order: "Delivery order",
  criteria: "Release criteria",
}

const HASH_ALIASES: Record<string, string> = {
  summary: "overview",
  "changed-files": "files",
  sections: "context",
  "recommended-order": "order",
  "exit-criteria": "criteria",
}

export function isViewId(id: string): id is ViewId {
  return (VIEW_IDS as readonly string[]).includes(id)
}

/**
 * Normalizes a location hash into its canonical target id: a view id, an epic id (`E1`),
 * a story id (`E1.S1`), a section id, a file id (`file-0`) or an in-prose anchor id.
 * Legacy aliases (`#summary`, `#epic-E1`, `#story-E1-S1`, `#section-x`, ...) are resolved.
 */
export function normalizeHashId(hash: string): string {
  let id: string

  try {
    id = decodeURIComponent(hash.replace(/^#/, "")) || "overview"
  } catch {
    id = "overview"
  }

  id = HASH_ALIASES[id] ?? id

  if (/^epic-E\d+$/.test(id)) id = id.slice(5)
  if (/^story-E\d+-S\d+$/.test(id)) id = id.slice(6).replace("-", ".")
  if (id.startsWith("section-")) id = id.slice(8)

  return id
}

/** Returns the DOM id that a hash points at (`view-<id>` for the six workspace views). */
export function hashDomTargetId(hash: string): string {
  const id = normalizeHashId(hash)
  return isViewId(id) ? `view-${id}` : id
}

/** Resolves a hash to its DOM element, or null when nothing in the document matches. */
export function targetForHash(hash: string): HTMLElement | null {
  if (typeof document === "undefined") return null
  return document.getElementById(hashDomTargetId(hash))
}

export function fileDomId(index: number): string {
  return `file-${index}`
}
