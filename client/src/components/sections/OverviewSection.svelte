<script lang="ts">
  import type { Plan } from "../../../../src/plan"
  import ChonkHeroArt from "../ui/ChonkHeroArt.svelte"
  import {
    splitHeroTitle,
    countProposedFiles,
    getFirstStory,
    formatMetadataKey,
  } from "../../lib/overviewHelpers"

  export let plan: Plan
  export let hidden = false

  $: hero = splitHeroTitle(plan.title, plan.heroTitle, plan.project)
  $: description = plan.scope || (plan.summary && plan.summary.length > 0 ? plan.summary[0] : "")
  $: epics = plan.epics || []
  $: epicsCount = epics.length
  $: storiesCount = epics.reduce((acc, epic) => acc + (epic.stories?.length || 0), 0)
  $: filesCount = countProposedFiles(plan.changedFiles)
  $: criteriaCount = plan.exitCriteria?.length || 0
  $: firstStory = getFirstStory(plan)
</script>

<section class="page-view hero" id="view-overview" data-view="overview" {hidden}>
  <div class="eva-hero">
    <div class="page-heading">
      <h1>
        {hero.lead}
        {#if hero.accent}
          {" "}<span class="release-word">{hero.accent}</span>
        {/if}
      </h1>
      {#if description}
        <p class="page-description">{description}</p>
      {/if}
    </div>

    <div class="release-plate" aria-hidden="true">
      <strong class="plate-number">01</strong>
    </div>

    <ChonkHeroArt />
  </div>

  <div class="plan-counts" aria-label="Plan at a glance">
    <span><strong>{epicsCount}</strong> {epicsCount === 1 ? "epic" : "epics"}</span>
    <span><strong>{storiesCount}</strong> {storiesCount === 1 ? "story" : "stories"}</span>
    <span><strong>{filesCount}</strong> proposed files</span>
    <span><strong>{criteriaCount}</strong> release criteria</span>
  </div>

  <div class="overview-grid">
    <section>
      <div class="section-heading">
        <h2>Epics &amp; Stories</h2>
        <a href="#epics">View all stories <svg aria-hidden="true"><use href="#i-arrow" /></svg></a>
      </div>
      <div class="epic-index">
        {#each epics as epic}
          <a class="epic-index-row" href="#{epic.id}">
            <span class="epic-index-number">{epic.id}</span>
            <div class="epic-index-info">
              <strong>{epic.shortTitle || epic.title}</strong>
            </div>
            <span class="epic-index-meta"
              >{epic.stories?.length || 0} {epic.stories?.length === 1 ? "story" : "stories"}</span
            >
            <svg aria-hidden="true"><use href="#i-chevron" /></svg>
          </a>
        {/each}
      </div>
    </section>

    <div class="overview-side">
      {#if firstStory}
        <section class="first-story">
          <h2>{firstStory.title}{firstStory.title.endsWith(".") ? "" : "."}</h2>
          {#if firstStory.summary}
            <p>{firstStory.summary}</p>
          {/if}
          <a class="btn" href="#{firstStory.id}">
            Open first story <svg aria-hidden="true"><use href="#i-arrow" /></svg>
          </a>
        </section>
      {/if}
    </div>
  </div>

  {#if plan.summary && plan.summary.length > 0}
    <section class="plan-brief">
      <h2>The plan, in brief</h2>
      <div class="brief-paragraphs">
        {#each plan.summary as paragraph}
          <p>{paragraph}</p>
        {/each}
      </div>
    </section>
  {/if}

  <details class="plan-details">
    <summary><svg aria-hidden="true"><use href="#i-book" /></svg>Plan details &amp; source references</summary>
    <div class="metadata-content">
      <dl><dt>Original title</dt><dd>{plan.title}</dd></dl>
      {#if plan.generatedAt}
        <dl><dt>Generated</dt><dd>{plan.generatedAt}</dd></dl>
      {/if}
      {#if plan.metadata}
        {#each Object.entries(plan.metadata) as [key, value]}
          {#if Array.isArray(value)}
            <h3>{formatMetadataKey(key)}</h3>
            <ul>
              {#each value as item}
                <li>{String(item)}</li>
              {/each}
            </ul>
          {:else if typeof value === "object" && value !== null}
            <h3>{formatMetadataKey(key)}</h3>
            <dl>
              {#each Object.entries(value) as [subKey, subVal]}
                <dt>{formatMetadataKey(subKey)}</dt>
                <dd>{String(subVal)}</dd>
              {/each}
            </dl>
          {:else}
            <dl>
              <dt>{formatMetadataKey(key)}</dt>
              <dd>{String(value)}</dd>
            </dl>
          {/if}
        {/each}
      {/if}
    </div>
  </details>
</section>
