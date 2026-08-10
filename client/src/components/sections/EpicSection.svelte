<script lang="ts">
  import type { Epic } from "../../../../src/plan.ts"
  import { epicDomId } from "../../lib/ids.ts"
  import Pill from "../ui/Pill.svelte"
  import PillRow from "../ui/PillRow.svelte"
  import MarkdownText from "../ui/MarkdownText.svelte"
  import StoryCard from "../cards/StoryCard.svelte"

  export let epic: Epic
</script>

<section class="document-section" id={epicDomId(epic.id)}>
  <header class="section-header">
    <h1 class="section-title">{epic.id}: {epic.title}</h1>
    {#if epic.summary}
      <p class="page-subtitle">{epic.summary}</p>
    {/if}
  </header>

  {#if epic.status || epic.testFocus || (epic.tags && epic.tags.length > 0)}
    <PillRow>
      {#if epic.status}
        <Pill label={`status: ${epic.status}`} variant="status" />
      {/if}
      {#if epic.testFocus}
        <Pill label={`test focus: ${epic.testFocus}`} />
      {/if}
      {#each epic.tags ?? [] as tag}
        <Pill label={tag} />
      {/each}
    </PillRow>
  {/if}

  {#if epic.description}
    <div class="epic-description">
      <MarkdownText markdown={epic.description} />
    </div>
  {/if}

  {#each epic.stories as story}
    <StoryCard {story} />
  {/each}
</section>

<style>
  .epic-description {
    margin-bottom: 1.5rem;
  }
</style>
