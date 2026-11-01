import type { FileTree, FileTreeNode, Plan } from "../../../src/plan"
import { computeChildPath } from "./fileTreeHelpers"
import { VIEW_IDS, VIEW_TITLES } from "./ids"

export type SearchKind = "story" | "epic" | "section" | "file" | "page"

export interface SearchItem {
  id: string
  kind: SearchKind
  label: string
  title: string
  info: string
  text: string
}

export interface HighlightSegment {
  text: string
  match: boolean
}

export const MAX_SEARCH_RESULTS = 30

function lower(value: unknown): string {
  return JSON.stringify(value ?? "").toLowerCase()
}

function collectFiles(trees: FileTree[], fileIds: Map<string, string>): SearchItem[] {
  const items: SearchItem[] = []

  function traverse(node: FileTreeNode, parentPath: string): void {
    const path = computeChildPath(parentPath, node.name, node.path)
    if (node.type === "file") {
      const id = fileIds.get(path)
      if (!id) return
      const stories = node.stories?.length ? node.stories.join(", ") : "no linked stories"
      items.push({
        id,
        kind: "file",
        label: "FILE",
        title: path,
        info: `Proposed ${node.status ?? "unchanged"} file · ${stories}`,
        text: `${path} ${node.status ?? ""} ${(node.stories ?? []).join(" ")}`.toLowerCase(),
      })
      return
    }
    for (const child of node.children ?? []) traverse(child, path)
  }

  for (const tree of trees ?? []) {
    if (tree.root) traverse(tree.root, "")
  }
  return items
}

/** Builds the flat, searchable index of every story, epic, context section, file and page. */
export function buildSearchIndex(plan: Plan, fileIds: Map<string, string>): SearchItem[] {
  const epics = plan.epics ?? []
  const items: SearchItem[] = []

  for (const epic of epics) {
    for (const story of epic.stories ?? []) {
      items.push({
        id: story.id,
        kind: "story",
        label: story.id,
        title: story.title,
        info: `${epic.id} · ${story.risk ?? "unrated"} risk · ${story.filesLikelyTouched?.length ?? 0} files`,
        text: lower(story),
      })
    }
  }

  for (const epic of epics) {
    items.push({
      id: epic.id,
      kind: "epic",
      label: epic.id,
      title: epic.title,
      info: `${epic.stories?.length ?? 0} stories${epic.summary ? ` · ${epic.summary}` : ""}`,
      text: `${epic.title} ${epic.summary ?? ""} ${epic.description ?? ""}`.toLowerCase(),
    })
  }

  for (const section of plan.sections ?? []) {
    items.push({
      id: section.id,
      kind: "section",
      label: "CONTEXT",
      title: section.title,
      info: `${section.items?.length ?? 0} decisions & references`,
      text: lower(section),
    })
  }

  for (const id of VIEW_IDS) {
    items.push({
      id,
      kind: "page",
      label: "PAGE",
      title: VIEW_TITLES[id],
      info: "Plan navigation",
      text: VIEW_TITLES[id].toLowerCase(),
    })
  }

  items.push(...collectFiles(plan.changedFiles ?? [], fileIds))
  return items
}

export function queryWords(query: string): string[] {
  return query.trim().toLowerCase().split(/\s+/).filter(Boolean)
}

/** Items matching every query word, in index order. */
export function filterSearch(items: SearchItem[], query: string): SearchItem[] {
  const words = queryWords(query)
  if (words.length === 0) return []
  return items.filter((item) => words.every((word) => item.text.includes(word)))
}

/** Destinations offered before the user has typed anything. */
export function suggestedItems(items: SearchItem[]): SearchItem[] {
  const firstStory = items.find((item) => item.kind === "story")
  const epics = items.filter((item) => item.kind === "epic")
  const pages = items.filter((item) => item.kind === "page" && (item.id === "order" || item.id === "criteria"))
  return [...(firstStory ? [firstStory] : []), ...epics, ...pages].slice(0, MAX_SEARCH_RESULTS)
}

/** Splits text into plain and matching segments for every query word occurrence (case-insensitive). */
export function highlightSegments(text: string, query: string): HighlightSegment[] {
  const words = queryWords(query)
  if (words.length === 0 || !text) return [{ text, match: false }]

  const haystack = text.toLowerCase()
  const ranges: Array<[number, number]> = []
  for (const word of words) {
    let from = 0
    while (from <= haystack.length - word.length) {
      const index = haystack.indexOf(word, from)
      if (index < 0) break
      ranges.push([index, index + word.length])
      from = index + word.length
    }
  }
  if (ranges.length === 0) return [{ text, match: false }]

  ranges.sort((a, b) => a[0] - b[0] || b[1] - a[1])
  const merged: Array<[number, number]> = []
  for (const range of ranges) {
    const last = merged[merged.length - 1]
    if (last && range[0] <= last[1]) last[1] = Math.max(last[1], range[1])
    else merged.push([range[0], range[1]])
  }

  const segments: HighlightSegment[] = []
  let cursor = 0
  for (const [start, end] of merged) {
    if (start > cursor) segments.push({ text: text.slice(cursor, start), match: false })
    segments.push({ text: text.slice(start, end), match: true })
    cursor = end
  }
  if (cursor < text.length) segments.push({ text: text.slice(cursor), match: false })
  return segments
}
