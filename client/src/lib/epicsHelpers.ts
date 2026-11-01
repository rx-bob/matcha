import type { Epic } from "../../../src/plan"

export interface StoryFilterState {
  storyVisibility: Record<string, boolean>
  epicVisibility: Record<string, boolean>
  totalStories: number
  visibleStories: number
}

export function filterEpicsAndStories(
  epics: Epic[],
  query: string,
): StoryFilterState {
  const words = query
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean)

  const storyVisibility: Record<string, boolean> = {}
  const epicVisibility: Record<string, boolean> = {}

  let totalStories = 0
  let visibleStories = 0

  for (const epic of epics) {
    let epicHasVisibleStory = false
    for (const story of epic.stories ?? []) {
      totalStories++
      const textIndex = JSON.stringify(story).toLowerCase()
      const matchesWords = words.length === 0 || words.every((w) => textIndex.includes(w))
      const isVisible = matchesWords

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
