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

/// Re-export JsonValue for callers that build catalog fixtures.
export type { JsonValue }
