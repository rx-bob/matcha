<script lang="ts">
  import type { Story } from "../../../../src/plan.ts"
  import { storyDomId } from "../../lib/ids.ts"
  import Pill from "../ui/Pill.svelte"
  import PillRow from "../ui/PillRow.svelte"
  import MarkdownText from "../ui/MarkdownText.svelte"
  import StoryListSection from "./StoryListSection.svelte"

  export let story: Story
</script>

<article class="story-card" id={storyDomId(story.id)}>
  <div class="story-header">
    <h2 class="story-title">{story.id}: {story.title}</h2>

    {#if story.status || story.risk || story.priority}
      <PillRow>
        {#if story.status}
          <Pill label={story.status} variant="status" />
        {/if}
        {#if story.risk}
          <Pill label={`risk: ${story.risk}`} />
        {/if}
        {#if story.priority}
          <Pill label={`priority: ${story.priority}`} />
        {/if}
      </PillRow>
    {/if}
  </div>

  {#if story.description}
    <div class="story-description">
      <MarkdownText markdown={story.description} />
    </div>
  {/if}

  <StoryListSection title="Details" items={story.details} />
  <StoryListSection title="Acceptance Criteria" items={story.acceptanceCriteria} />
  <StoryListSection title="Tests" items={story.unitTests} />
  <StoryListSection title="Dependencies" items={story.dependencies} linkMode="story" />
  <StoryListSection title="Files Likely Touched" items={story.filesLikelyTouched} />
  <StoryListSection title="Commands To Run" items={story.commandsToRun} />
  <StoryListSection title="Artifacts" items={story.artifacts} />
  <StoryListSection title="Notes" items={story.notes} />
</article>

<style>
  .story-description {
    margin-bottom: 1rem;
  }
</style>
