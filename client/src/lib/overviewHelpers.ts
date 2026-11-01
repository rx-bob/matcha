import type { Plan, HeroTitle, FileTree, FileTreeNode, Story } from "../../../src/plan"

export function splitHeroTitle(
  title: string,
  heroTitle?: HeroTitle,
  project?: string
): { lead: string; accent: string } {
  if (heroTitle) {
    if (typeof heroTitle === "object" && heroTitle !== null && "lead" in heroTitle) {
      return {
        lead: heroTitle.lead,
        accent: heroTitle.accent ?? "",
      }
    }
    if (typeof heroTitle === "string") {
      const trimmed = heroTitle.trim()
      const words = trimmed.split(/\s+/).filter(Boolean)
      if (words.length > 1) {
        return {
          lead: words.slice(0, -1).join(" "),
          accent: words[words.length - 1],
        }
      }
      return { lead: trimmed, accent: "" }
    }
  }

  let cleaned = (title || "").trim()

  if (project) {
    const prefixRegex = new RegExp(`^${escapeRegex(project)}:\\s*`, "i")
    if (prefixRegex.test(cleaned)) {
      cleaned = cleaned.replace(prefixRegex, "").trim()
    } else if (cleaned.includes(":")) {
      cleaned = cleaned.slice(cleaned.indexOf(":") + 1).trim()
    }
  } else if (cleaned.includes(":")) {
    cleaned = cleaned.slice(cleaned.indexOf(":") + 1).trim()
  }

  const words = cleaned.split(/\s+/).filter(Boolean)
  if (words.length > 1) {
    return {
      lead: words.slice(0, -1).join(" "),
      accent: words[words.length - 1],
    }
  }

  return { lead: cleaned, accent: "" }
}

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

export function countProposedFiles(files?: FileTree[]): number {
  if (!files || files.length === 0) return 0

  function countNode(node: FileTreeNode): number {
    let count = node.type === "file" ? 1 : 0
    if (node.children) {
      for (const child of node.children) {
        count += countNode(child)
      }
    }
    return count
  }

  let total = 0
  for (const tree of files) {
    if (tree.root) {
      total += countNode(tree.root)
    }
  }
  return total
}

export function getFirstStory(
  plan: Plan
): { id: string; title: string; summary: string } | null {
  const allStories: Story[] = (plan.epics || []).flatMap((epic) => epic.stories || [])

  let firstStory: Story | null = null

  if (plan.recommendedOrder && plan.recommendedOrder.length > 0) {
    const firstRef = plan.recommendedOrder[0].ref
    firstStory = allStories.find((s) => s.id === firstRef) || null
  }

  if (!firstStory && plan.epics && plan.epics.length > 0) {
    firstStory = plan.epics[0].stories?.[0] || null
  }

  if (!firstStory) return null

  let summary = ""
  if (plan.firstStorySummary) {
    summary = plan.firstStorySummary
  } else if (firstStory.details && firstStory.details.length > 0) {
    summary = extractFirstSentence(firstStory.details[0])
  } else if (firstStory.description) {
    summary = extractFirstSentence(firstStory.description)
  }

  return {
    id: firstStory.id,
    title: firstStory.title,
    summary,
  }
}

function extractFirstSentence(text: string): string {
  const trimmed = text.trim()
  const match = trimmed.match(/^([^.?!]+[.?!])(?:\s|$)/)
  return match ? match[1] : trimmed
}

export function formatMetadataKey(key: string): string {
  const withSpaces = key
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .trim()
  if (!withSpaces) return key
  return withSpaces.charAt(0).toUpperCase() + withSpaces.slice(1).toLowerCase()
}

export function resolveViewForHash(hash: string, plan?: Plan): string {
  const clean = hash.replace(/^#/, "")
  if (!clean) return "overview"

  if (["overview", "epics", "files", "context", "order", "criteria"].includes(clean)) {
    return clean
  }

  if (clean === "summary" || clean === "plan") return "overview"
  if (clean === "changed-files" || clean.startsWith("file-")) return "files"
  if (clean === "sections") return "context"
  if (clean === "recommended-order") return "order"
  if (clean === "exit-criteria") return "criteria"

  if (plan?.sections?.some((s) => s.id === clean || `section-${s.id}` === clean)) {
    return "context"
  }

  if (/^E\d+(\.S\d+)?$/.test(clean) || /^epic-E\d+$/.test(clean) || /^story-E\d+-S\d+$/.test(clean)) {
    return "epics"
  }

  return "overview"
}
