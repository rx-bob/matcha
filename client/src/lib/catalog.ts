import type { JsonValue } from "../../src/plan.ts"

export type ArtifactKind = "plan" | "map"

export interface CatalogArtifact {
  relPath: string
  url: string
  kind: ArtifactKind
  group: string
  size: number
  mtime: number
  title?: string
  project?: string
  status?: string
  generatedAt?: string
  diagramKind?: string
}

export interface CatalogWarning {
  relPath: string
  reason: string
}

export interface CatalogProject {
  name: string
  artifacts: CatalogArtifact[]
}

export interface Catalog {
  projects: CatalogProject[]
  warnings: CatalogWarning[]
}

/// Maximum mtime value that fits safely in a JS number (nanoseconds).
/// Dates beyond ~2085 exceed Number.MAX_SAFE_INTEGER when expressed in ns.
const MAX_SAFE_MTIME_NS = Number.MAX_SAFE_INTEGER

/// Convert a nanosecond mtime from the catalog into milliseconds since the
/// epoch, safely handling values that exceed Number.MAX_SAFE_INTEGER. Returns
/// null when the value is missing or not a finite number.
export function mtimeToMillis(mtime: number): number | null {
  if (!Number.isFinite(mtime) || mtime <= 0) return null
  if (mtime > MAX_SAFE_MTIME_NS) {
    // BigInt-safe path for post-2085 nanosecond timestamps.
    const ms = Number(BigInt(Math.trunc(mtime)) / 1_000_000n)
    return Number.isFinite(ms) ? ms : null
  }
  return Math.trunc(mtime / 1_000_000)
}

/// Format a nanosecond mtime as a human-readable local date/time string.
/// Returns an empty string when the value is missing or unparsable so the
/// UI never renders "Invalid Date".
export function formatMtime(mtime: number): string {
  const ms = mtimeToMillis(mtime)
  if (ms === null || !Number.isFinite(ms)) return ""
  const date = new Date(ms)
  if (Number.isNaN(date.getTime())) return ""
  return date.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  })
}

/// Format an ISO-8601 generatedAt string as a human-readable local date/time.
/// Returns an empty string when the value is missing or unparsable.
export function formatGeneratedAt(generatedAt: string | undefined): string {
  if (!generatedAt) return ""
  const date = new Date(generatedAt)
  if (Number.isNaN(date.getTime())) return ""
  return date.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  })
}

/// The display model for a single artifact card. Optional fields are coerced
/// to empty strings so the view never renders "undefined" or "null" labels.
export interface ArtifactDisplay {
  relPath: string
  url: string
  kind: ArtifactKind
  title: string
  status: string
  generatedAt: string
  generatedAtRaw: string
  diagramKind: string
  filename: string
  mtime: string
  size: number
}

/// The display model for a project section.
export interface ProjectDisplay {
  name: string
  artifacts: ArtifactDisplay[]
}

/// Compute the basename (final path segment) of a relative path that uses
/// forward slashes. Returns the full path when it contains no slash.
export function basename(relPath: string): string {
  const idx = relPath.lastIndexOf("/")
  return idx === -1 ? relPath : relPath.slice(idx + 1)
}

/// Build a deterministic display title for an artifact. The embedded document
/// title wins when present and non-empty; otherwise the filename is used so
/// the card always has a readable label.
export function displayTitle(artifact: CatalogArtifact): string {
  if (artifact.title && artifact.title.trim().length > 0) {
    return artifact.title
  }
  return basename(artifact.relPath)
}

/// Transform a raw catalog artifact into a display model with all optional
/// fields resolved to safe empty strings and human-readable timestamps.
export function toArtifactDisplay(artifact: CatalogArtifact): ArtifactDisplay {
  return {
    relPath: artifact.relPath,
    url: artifact.url,
    kind: artifact.kind,
    title: displayTitle(artifact),
    status: artifact.status ?? "",
    generatedAt: formatGeneratedAt(artifact.generatedAt),
    generatedAtRaw: artifact.generatedAt ?? "",
    diagramKind: artifact.diagramKind ?? "",
    filename: basename(artifact.relPath),
    mtime: formatMtime(artifact.mtime),
    size: artifact.size,
  }
}

/// Transform a raw catalog into a list of project display models. Projects
/// with zero artifacts are preserved (they are informational). Ordering is
/// preserved from the server, which already sorts deterministically by
/// group, kind (plan before map), and relative path.
export function toProjectDisplays(catalog: Catalog): ProjectDisplay[] {
  return catalog.projects.map((project) => ({
    name: project.name,
    artifacts: project.artifacts.map(toArtifactDisplay),
  }))
}

/// Count the total number of artifacts across all projects. Used to detect
/// the empty-library state (projects may be present but all empty, or the
/// server may return a synthetic Ungrouped placeholder).
export function totalArtifactCount(catalog: Catalog): number {
  let count = 0
  for (const project of catalog.projects) {
    count += project.artifacts.length
  }
  return count
}

/// True when the catalog represents an empty library: no projects at all, or
/// every project has zero artifacts.
export function isEmptyCatalog(catalog: Catalog): boolean {
  return totalArtifactCount(catalog) === 0
}

/// Parse unknown JSON into a typed Catalog, defaulting missing fields to
/// empty arrays so the rest of the UI never sees undefined. Optional artifact
/// fields are left absent when the JSON omits them.
export function parseCatalog(value: unknown): Catalog {
  if (!isObject(value)) return { projects: [], warnings: [] }
  const projects = Array.isArray((value as { projects?: unknown }).projects)
    ? (value as { projects: unknown[] }).projects.map(parseProject).filter(Boolean) as CatalogProject[]
    : []
  const warnings = Array.isArray((value as { warnings?: unknown }).warnings)
    ? (value as { warnings: unknown[] }).warnings.map(parseWarning).filter(Boolean) as CatalogWarning[]
    : []
  return { projects, warnings }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

function parseProject(value: unknown): CatalogProject | null {
  if (!isObject(value)) return null
  const name = typeof value.name === "string" ? value.name : ""
  const artifacts = Array.isArray(value.artifacts)
    ? value.artifacts.map(parseArtifact).filter(Boolean) as CatalogArtifact[]
    : []
  return { name, artifacts }
}

function parseArtifact(value: unknown): CatalogArtifact | null {
  if (!isObject(value)) return null
  const relPath = typeof value.relPath === "string" ? value.relPath : ""
  const url = typeof value.url === "string" ? value.url : ""
  const kind: ArtifactKind = value.kind === "map" ? "map" : "plan"
  const group = typeof value.group === "string" ? value.group : ""
  const size = typeof value.size === "number" && Number.isFinite(value.size) ? value.size : 0
  const mtime = typeof value.mtime === "number" && Number.isFinite(value.mtime) ? value.mtime : 0
  const artifact: CatalogArtifact = {
    relPath,
    url,
    kind,
    group,
    size,
    mtime,
  }
  if (typeof value.title === "string") artifact.title = value.title
  if (typeof value.project === "string") artifact.project = value.project
  if (typeof value.status === "string") artifact.status = value.status
  if (typeof value.generatedAt === "string") artifact.generatedAt = value.generatedAt
  if (typeof value.diagramKind === "string") artifact.diagramKind = value.diagramKind
  return artifact
}

function parseWarning(value: unknown): CatalogWarning | null {
  if (!isObject(value)) return null
  const relPath = typeof value.relPath === "string" ? value.relPath : ""
  const reason = typeof value.reason === "string" ? value.reason : ""
  return { relPath, reason }
}

/// Type guard for the catalog JSON shape used by tests. Exposed for
/// potential future server contract validation.
export function isCatalog(value: unknown): value is Catalog {
  return isObject(value) && Array.isArray(value.projects) && Array.isArray(value.warnings)
}

/// Type filter selection for the catalog UI. "all" shows every artifact;
/// "plan" and "map" restrict to that kind.
export type TypeFilter = "all" | "plan" | "map"

/// Normalize a search query for case-insensitive, whitespace-tolerant
/// matching. Returns a lowercased string with runs of whitespace collapsed
/// to single spaces and trimmed. Empty or whitespace-only queries return an
/// empty string, which means "match everything".
export function normalizeSearch(query: string): string {
  if (!query) return ""
  return query.trim().toLowerCase().replace(/\s+/g, " ")
}

/// True when a normalized search query matches an artifact. The query is
/// tested against the project name, artifact title, and relative path. An
/// empty query matches every artifact so callers can combine search with a
/// type filter without short-circuiting.
export function artifactMatchesSearch(
  artifact: ArtifactDisplay,
  projectName: string,
  normalizedQuery: string,
): boolean {
  if (normalizedQuery.length === 0) return true
  if (projectName.toLowerCase().includes(normalizedQuery)) return true
  if (artifact.title.toLowerCase().includes(normalizedQuery)) return true
  if (artifact.relPath.toLowerCase().includes(normalizedQuery)) return true
  return false
}

/// True when an artifact passes the type filter. "all" passes every kind.
export function artifactMatchesFilter(artifact: ArtifactDisplay, filter: TypeFilter): boolean {
  if (filter === "all") return true
  return artifact.kind === filter
}

/// Filter a list of project display models by a combined search query and
/// type filter. Projects whose artifacts all fail the filters are dropped so
/// the UI never renders empty project sections. Project ordering and the
/// artifact ordering within each surviving project are preserved (server
/// determinism). The caller is expected to pass an already-normalized
/// search query via `normalizeSearch`.
export function filterProjects(
  projects: ProjectDisplay[],
  normalizedQuery: string,
  filter: TypeFilter,
): ProjectDisplay[] {
  if (normalizedQuery.length === 0 && filter === "all") {
    return projects.filter((p) => p.artifacts.length > 0)
  }
  const result: ProjectDisplay[] = []
  for (const project of projects) {
    const matching = project.artifacts.filter(
      (artifact) =>
        artifactMatchesFilter(artifact, filter) &&
        artifactMatchesSearch(artifact, project.name, normalizedQuery),
    )
    if (matching.length > 0) {
      result.push({ name: project.name, artifacts: matching })
    }
  }
  return result
}

/// Compare two catalog payloads for value equality. Used by the polling loop
/// to decide whether the displayed model needs to change after a successful
/// fetch. Compares the project names, artifact counts, and the per-artifact
/// relPath/url/kind/mtime/size tuple so unchanged rescans do not cause
/// rerender churn while genuine changes still refresh the view. Optional
/// metadata fields (title, status, generatedAt, diagramKind) are compared
/// too so edits that only change those fields still refresh.
export function catalogsEqual(a: Catalog, b: Catalog): boolean {
  if (a === b) return true
  if (a.projects.length !== b.projects.length) return false
  if (a.warnings.length !== b.warnings.length) return false
  for (let i = 0; i < a.projects.length; i++) {
    const ap = a.projects[i]
    const bp = b.projects[i]
    if (ap.name !== bp.name) return false
    if (ap.artifacts.length !== bp.artifacts.length) return false
    for (let j = 0; j < ap.artifacts.length; j++) {
      if (!artifactsEqual(ap.artifacts[j], bp.artifacts[j])) return false
    }
  }
  for (let i = 0; i < a.warnings.length; i++) {
    if (a.warnings[i].relPath !== b.warnings[i].relPath) return false
    if (a.warnings[i].reason !== b.warnings[i].reason) return false
  }
  return true
}

function artifactsEqual(a: CatalogArtifact, b: CatalogArtifact): boolean {
  return (
    a.relPath === b.relPath &&
    a.url === b.url &&
    a.kind === b.kind &&
    a.group === b.group &&
    a.size === b.size &&
    a.mtime === b.mtime &&
    a.title === b.title &&
    a.project === b.project &&
    a.status === b.status &&
    a.generatedAt === b.generatedAt &&
    a.diagramKind === b.diagramKind
  )
}

/// State machine for the catalog polling loop. The loop drives transitions
/// between fetch attempts so behavior is deterministic and unit-testable
/// without a real timer. The machine is pure: callers feed it events and
/// read the next state, then apply side effects (network, timers, DOM).
export type PollState =
  | { phase: "idle" }
  | { phase: "fetching" }
  | { phase: "paused" }

export type PollEvent =
  | { type: "start" }
  | { type: "stop" }
  | { type: "fetch-succeeded"; catalog: Catalog; unchanged: boolean }
  | { type: "fetch-failed" }
  | { type: "visibility"; hidden: boolean }
  | { type: "interval-elapsed" }

/// Advance the polling state machine by one event. Returns the next state
/// and the side effect the caller should perform.
export type PollEffect =
  | { kind: "none" }
  | { kind: "fetch" }
  | { kind: "schedule-next" }
  | { kind: "pause" }
  | { kind: "resume" }

export function reducePoll(
  state: PollState,
  event: PollEvent,
): { state: PollState; effect: PollEffect } {
  switch (event.type) {
    case "start":
      return { state: { phase: "fetching" }, effect: { kind: "fetch" } }
    case "stop":
      return { state: { phase: "idle" }, effect: { kind: "none" } }
    case "fetch-succeeded":
      if (state.phase === "idle") return { state, effect: { kind: "none" } }
      return { state: { phase: "fetching" }, effect: { kind: "schedule-next" } }
    case "fetch-failed":
      if (state.phase === "idle") return { state, effect: { kind: "none" } }
      return { state: { phase: "fetching" }, effect: { kind: "schedule-next" } }
    case "visibility":
      if (event.hidden) {
        if (state.phase === "fetching") {
          return { state: { phase: "paused" }, effect: { kind: "pause" } }
        }
        // Already paused or idle: nothing to do.
        return { state, effect: { kind: "none" } }
      }
      // became visible
      if (state.phase === "paused") {
        return { state: { phase: "fetching" }, effect: { kind: "resume" } }
      }
      return { state, effect: { kind: "none" } }
    case "interval-elapsed":
      if (state.phase === "fetching") {
        return { state: { phase: "fetching" }, effect: { kind: "fetch" } }
      }
      return { state, effect: { kind: "none" } }
  }
}

/// Re-export JsonValue for callers that build catalog fixtures.
export type { JsonValue }
