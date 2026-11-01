<script lang="ts">
  import type { Epic } from "../../../../src/plan.ts"
  import MarkdownText from "../ui/MarkdownText.svelte"
  import {
    extractAvailableRisks,
    filterEpicsAndStories,
    type StoryFilterState,
  } from "../../lib/epicsHelpers"
  import { showToast } from "../../lib/toast"
  import { onMount } from "svelte"
  import { CLEAR_STORY_FILTERS_EVENT } from "../../lib/router"

  export let epics: Epic[] | undefined = []

  let searchQuery = ""
  let selectedRisk = "all"

  $: allEpics = epics ?? []
  $: availableRisks = extractAvailableRisks(allEpics)
  $: filterState = filterEpicsAndStories(allEpics, searchQuery, selectedRisk)
  $: countText =
    filterState.visibleStories === filterState.totalStories
      ? `${filterState.totalStories} stories`
      : `${filterState.visibleStories} of ${filterState.totalStories} stories`

  function handleFilter(): void {
    filterState = filterEpicsAndStories(allEpics, searchQuery, selectedRisk)
  }

  function handleCollapseStories(): void {
    if (typeof document !== "undefined") {
      const details = document.querySelectorAll<HTMLDetailsElement>("#view-epics details")
      details.forEach((d) => {
        d.open = false
      })
      showToast("Design references collapsed")
    }
  }

  onMount(() => {
    const clear = (): void => {
      searchQuery = ""
      selectedRisk = "all"
    }
    window.addEventListener(CLEAR_STORY_FILTERS_EVENT, clear)
    return () => window.removeEventListener(CLEAR_STORY_FILTERS_EVENT, clear)
  })

  function handleClearFilters(): void {
    searchQuery = ""
    selectedRisk = "all"
    handleFilter()
    if (typeof document !== "undefined") {
      const input = document.getElementById("story-filter") as HTMLInputElement | null
      input?.focus()
    }
  }

  function formatStoryLegacyId(epicId: string, storyId: string): string {
    const numPart = storyId.includes(".") ? storyId.split(".")[1] : storyId
    return `story-${epicId}-${numPart}`
  }
</script>

<div class="epics-toolbar">
  <label class="filter-input-wrap">
    <svg aria-hidden="true"><use href="#i-search" /></svg>
    <input
      type="search"
      id="story-filter"
      placeholder="Filter stories…"
      aria-label="Filter implementation stories"
      bind:value={searchQuery}
      on:input={handleFilter}
    />
  </label>
  <select
    id="risk-filter"
    aria-label="Filter by risk"
    bind:value={selectedRisk}
    on:change={handleFilter}
  >
    <option value="all">All risk levels</option>
    {#each availableRisks as r}
      <option value={r}>{r[0].toUpperCase() + r.slice(1)} risk</option>
    {/each}
  </select>
  <span class="filter-count" id="filter-count" aria-live="polite">{countText}</span>
  <button class="btn" id="collapse-stories" type="button" on:click={handleCollapseStories}>
    Collapse examples
  </button>
</div>

<div class="empty-state" id="filter-empty" hidden={filterState.visibleStories !== 0}>
  <strong>No matching stories</strong>
  <p>Try another term or clear your filters.</p>
  <button class="btn" id="clear-filters" type="button" on:click={handleClearFilters}>
    Clear filters
  </button>
</div>

{#each allEpics as epic (epic.id)}
  <article
    id={epic.id}
    class="epic-card"
    data-epic={epic.id}
    hidden={!filterState.epicVisibility[epic.id]}
  >
    <span id="epic-{epic.id}" class="legacy-anchor"></span>
    <header class="epic-header">
      <span class="epic-id">{epic.id}</span>
      <div class="epic-heading-text">
        <h2>{epic.title}</h2>
        {#if epic.summary}
          <p class="epic-summary">{epic.summary}</p>
        {/if}
      </div>
      {#if epic.dependencies && epic.dependencies.length > 0}
        <div class="dependency-list">
          <span class="dependency-label">Depends on</span>
          {#each epic.dependencies as dep}
            <a href="#{dep}" class="story-link"><code>{dep}</code></a>
          {/each}
        </div>
      {/if}
    </header>

    {#if epic.description}
      <details class="design-reference">
        <summary>Design reference &amp; examples</summary>
        <MarkdownText markdown={epic.description} />
      </details>
    {/if}

    <div class="story-list">
      {#each epic.stories as story (story.id)}
        <article
          class="story-card"
          id={story.id}
          data-risk={story.risk || "medium"}
          data-story={story.id}
          hidden={!filterState.storyVisibility[story.id]}
        >
          <button
            type="button"
            class="story-row"
            data-open-story={story.id}
            aria-haspopup="dialog"
            aria-controls="story-dialog"
          >
            <span class="story-status" aria-label={story.status || "Planned"}></span>
            <code class="story-id">{story.id}</code>
            <span class="story-title">{story.title}</span>
            <span class="risk-badge {story.risk || 'medium'}">
              {story.risk
                ? `${story.risk[0].toUpperCase()}${story.risk.slice(1)} risk`
                : "Medium risk"}
            </span>
            <svg
              class="story-chevron"
              viewBox="0 0 16 16"
              width="16"
              height="16"
              aria-hidden="true"
            >
              <path
                d="m6 4 4 4-4 4"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
          </button>
          <span id={formatStoryLegacyId(epic.id, story.id)} class="legacy-anchor"></span>

          <div class="story-body" hidden>
            {#if story.details && story.details.length > 0}
              <section class="detail-section">
                <h3>Implementation details</h3>
                <ul class="detail-list">
                  {#each story.details as item}
                    <li>{item}</li>
                  {/each}
                </ul>
              </section>
            {/if}

            {#if story.acceptanceCriteria && story.acceptanceCriteria.length > 0}
              <section class="detail-section">
                <h3>Acceptance criteria</h3>
                <ul class="detail-list">
                  {#each story.acceptanceCriteria as item}
                    <li>{item}</li>
                  {/each}
                </ul>
              </section>
            {/if}

            {#if story.unitTests && story.unitTests.length > 0}
              <section class="detail-section">
                <h3>Tests</h3>
                <ul class="detail-list">
                  {#each story.unitTests as item}
                    <li>{item}</li>
                  {/each}
                </ul>
              </section>
            {/if}

            {#if story.filesLikelyTouched && story.filesLikelyTouched.length > 0}
              <section class="detail-section">
                <h3>Files likely touched</h3>
                <ul class="file-list">
                  {#each story.filesLikelyTouched as file}
                    <li><code>{file}</code></li>
                  {/each}
                </ul>
              </section>
            {/if}

            {#if story.dependencies && story.dependencies.length > 0}
              <section class="detail-section">
                <h3>Dependencies</h3>
                <ul class="story-dependencies">
                  {#each story.dependencies as dep}
                    <li><a href="#{dep}" class="story-link"><code>{dep}</code></a></li>
                  {/each}
                </ul>
              </section>
            {/if}

            {#if story.description}
              <details class="source-reference">
                <summary>Design &amp; source references</summary>
                <MarkdownText markdown={story.description} />
              </details>
            {/if}
          </div>
        </article>
      {/each}
    </div>
  </article>
{/each}
