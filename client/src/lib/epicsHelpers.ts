import type { Epic, Story } from "../../../src/plan"

export function extractAvailableRisks(epics: Epic[]): string[] {
  const presentRisks = new Set<string>()
  for (const epic of epics) {
    for (const story of epic.stories ?? []) {
      if (story.risk) {
        presentRisks.add(story.risk.toLowerCase())
      }
    }
  }
  const order = ["high", "medium", "low"]
  const sorted: string[] = []
  for (const r of order) {
    if (presentRisks.has(r)) {
      sorted.push(r)
      presentRisks.delete(r)
    }
  }
  for (const r of presentRisks) {
    sorted.push(r)
  }
  return sorted
}

export interface StoryFilterState {
  storyVisibility: Record<string, boolean>
  epicVisibility: Record<string, boolean>
  totalStories: number
  visibleStories: number
}

export function filterEpicsAndStories(
  epics: Epic[],
  query: string,
  riskFilter: string,
): StoryFilterState {
  const words = query
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean)

  const selectedRisk = riskFilter.toLowerCase()
  const storyVisibility: Record<string, boolean> = {}
  const epicVisibility: Record<string, boolean> = {}

  let totalStories = 0
  let visibleStories = 0

  for (const epic of epics) {
    let epicHasVisibleStory = false
    for (const story of epic.stories ?? []) {
      totalStories++
      const storyRisk = (story.risk || "medium").toLowerCase()
      const matchesRisk = selectedRisk === "all" || storyRisk === selectedRisk
      const textIndex = JSON.stringify(story).toLowerCase()
      const matchesWords = words.length === 0 || words.every((w) => textIndex.includes(w))
      const isVisible = matchesRisk && matchesWords

      storyVisibility[story.id] = isVisible
      if (isVisible) {
        visibleStories++
        epicHasVisibleStory = true
      }
    }
    epicVisibility[epic.id] = epicHasVisibleStory
  }

  return {
    storyVisibility,
    epicVisibility,
    totalStories,
    visibleStories,
  }
}
