<script lang="ts">
  import { onMount, onDestroy } from "svelte"
  import {
    catalogsEqual,
    filterProjects,
    isEmptyCatalog,
    normalizeSearch,
    parseCatalog,
    toProjectDisplays,
    totalArtifactCount,
    type Catalog,
    type ProjectDisplay,
    type TypeFilter,
  } from "./lib/catalog.ts"
  import ProjectSection from "./components/serve/ProjectSection.svelte"
  import EmptyState from "./components/serve/EmptyState.svelte"

  export let catalogUrl: string
  export let pollIntervalMs: number = 5000

  type LoadState = "loading" | "loaded" | "error"
  let state: LoadState = "loading"
  let errorMessage = ""
  let projects: ProjectDisplay[] = []
  let warningCount = 0
  let lastRefreshed: Date | null = null
  let refreshError = false

  // Search + filter state, preserved across refreshes.
  let searchInput = ""
  let typeFilter: TypeFilter = "all"

  // Polling control.
  let pollTimer: ReturnType<typeof setTimeout> | null = null
  let inFlight = false
  let destroyed = false

  function clearPollTimer(): void {
    if (pollTimer !== null) {
      clearTimeout(pollTimer)
      pollTimer = null
    }
  }

  function scheduleNextPoll(): void {
    clearPollTimer()
    if (destroyed) return
    if (typeof document !== "undefined" && document.hidden) return
    pollTimer = setTimeout(() => {
      void refreshCatalog()
    }, pollIntervalMs)
  }

  async function refreshCatalog(): Promise<void> {
    if (inFlight) return
    inFlight = true
    try {
      const response = await fetch(catalogUrl, {
        headers: { Accept: "application/json" },
      })
      if (!response.ok) {
        if (state === "loading") {
          state = "error"
          errorMessage = `Server returned ${response.status} ${response.statusText}`.trim()
        } else {
          // Recoverable: keep previous catalog, surface restrained error.
          refreshError = true
        }
        return
      }
      const json: unknown = await response.json()
      const newCatalog = parseCatalog(json)
      // Replace the displayed model only after a successful response, and
      // avoid rerender churn when the payload is unchanged.
      if (lastCatalog === null || !catalogsEqual(lastCatalog, newCatalog)) {
        projects = toProjectDisplays(newCatalog)
        warningCount = newCatalog.warnings.length
        lastCatalog = newCatalog
      }
      refreshError = false
      state = "loaded"
      lastRefreshed = new Date()
    } catch (err) {
      if (state === "loading") {
        state = "error"
        errorMessage = err instanceof Error ? err.message : "Catalog request failed"
      } else {
        refreshError = true
      }
    } finally {
      inFlight = false
      scheduleNextPoll()
    }
  }

  let lastCatalog: Catalog | null = null

  function handleVisibilityChange(): void {
    if (document.hidden) {
      clearPollTimer()
    } else {
      // Refresh immediately on returning to the tab, then resume polling.
      void refreshCatalog()
    }
  }

  onMount(() => {
    void refreshCatalog()
    document.addEventListener("visibilitychange", handleVisibilityChange)
  })

  onDestroy(() => {
    destroyed = true
    clearPollTimer()
    document.removeEventListener("visibilitychange", handleVisibilityChange)
  })

  $: normalizedQuery = normalizeSearch(searchInput)
  $: totalArtifacts =
    state === "loaded" ? projects.reduce((sum, p) => sum + p.artifacts.length, 0) : 0
  $: showEmpty = state === "loaded" && totalArtifacts === 0
  $: visibleProjects = filterProjects(projects, normalizedQuery, typeFilter)
  $: noMatches = state === "loaded" && totalArtifacts > 0 && visibleProjects.length === 0
  $: lastRefreshedLabel = lastRefreshed
    ? lastRefreshed.toLocaleTimeString(undefined, {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      })
    : ""
</script>

<main class="matcha-serve">
  <header class="serve-header">
    <h1>matcha serve</h1>
    {#if state === "loaded" && totalArtifacts > 0}
      <div class="serve-controls">
        <input
          class="serve-search"
          type="search"
          placeholder="Search project, title, or path"
          aria-label="Search catalog"
          bind:value={searchInput}
        />
        <div class="serve-filter" role="group" aria-label="Filter by type">
          <button
            class="serve-filter-btn"
            class:active={typeFilter === "all"}
            aria-pressed={typeFilter === "all"}
            on:click={() => (typeFilter = "all")}
          >All</button>
          <button
            class="serve-filter-btn"
            class:active={typeFilter === "plan"}
            aria-pressed={typeFilter === "plan"}
            on:click={() => (typeFilter = "plan")}
          >Plans</button>
          <button
            class="serve-filter-btn"
            class:active={typeFilter === "map"}
            aria-pressed={typeFilter === "map"}
            on:click={() => (typeFilter = "map")}
          >Maps</button>
        </div>
      </div>
      <p class="serve-summary">
        {totalArtifacts} artifact{totalArtifacts === 1 ? "" : "s"}
        {#if warningCount > 0}
          <span class="serve-warnings">({warningCount} warning{warningCount === 1 ? "" : "s"})</span>
        {/if}
        {#if lastRefreshedLabel}
          <span class="serve-refreshed">last refreshed {lastRefreshedLabel}</span>
        {/if}
        {#if refreshError}
          <span class="serve-refresh-error" role="alert">refresh failed; showing previous catalog</span>
        {/if}
      </p>
    {/if}
  </header>

  {#if state === "loading"}
    <p class="serve-loading" aria-live="polite">Loading catalog&hellip;</p>
  {:else if showEmpty}
    <EmptyState message="No Matcha-generated HTML was found. Place generated plan or map HTML files in the served directory." />
  {:else if state === "error"}
    <p class="serve-error" role="alert">
      Could not load the catalog: {errorMessage}
    </p>
    <button class="serve-retry" on:click={refreshCatalog}>Retry</button>
  {:else if noMatches}
    <p class="serve-no-matches">No artifacts match the current search or filter.</p>
  {:else}
    {#each visibleProjects as project (project.name)}
      <ProjectSection {project} />
    {/each}
  {/if}
</main>

<style>
  .matcha-serve {
    font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    max-width: 960px;
    margin: 0 auto;
    padding: 1.5rem;
    color: #333;
    line-height: 1.5;
  }
  .serve-header {
    margin-bottom: 1.5rem;
  }
  .serve-header h1 {
    margin: 0 0 0.75rem;
    font-size: 1.75rem;
    font-weight: 600;
  }
  .serve-controls {
    display: flex;
    flex-wrap: wrap;
    gap: 0.6rem;
    align-items: center;
    margin-bottom: 0.5rem;
  }
  .serve-search {
    flex: 1 1 220px;
    min-width: 0;
    padding: 0.4rem 0.6rem;
    font: inherit;
    font-size: 0.9rem;
    border: 1px solid #ccc;
    border-radius: 0.3rem;
    background: #fff;
    color: inherit;
  }
  .serve-search:focus-visible {
    outline: 2px solid #1e66f5;
    outline-offset: 1px;
  }
  .serve-filter {
    display: flex;
    gap: 0.25rem;
  }
  .serve-filter-btn {
    padding: 0.35rem 0.7rem;
    font: inherit;
    font-size: 0.8rem;
    border: 1px solid #ccc;
    border-radius: 0.3rem;
    background: #f8f8f8;
    cursor: pointer;
    color: inherit;
  }
  .serve-filter-btn:hover {
    background: #eee;
  }
  .serve-filter-btn.active {
    background: #1e66f5;
    color: #fff;
    border-color: #1e66f5;
  }
  .serve-filter-btn:focus-visible {
    outline: 2px solid #1e66f5;
    outline-offset: 1px;
  }
  .serve-summary {
    margin: 0;
    color: #666;
    font-size: 0.8rem;
  }
  .serve-warnings {
    margin-left: 0.5rem;
    color: #b8860b;
  }
  .serve-refreshed {
    margin-left: 0.5rem;
    color: #888;
  }
  .serve-refresh-error {
    margin-left: 0.5rem;
    color: #b22222;
  }
  .serve-loading,
  .serve-error,
  .serve-no-matches {
    padding: 1rem 0;
    font-size: 0.95rem;
  }
  .serve-error {
    color: #b22222;
  }
  .serve-no-matches {
    color: #666;
  }
  .serve-retry {
    margin-top: 0.5rem;
    padding: 0.4rem 0.8rem;
    font: inherit;
    font-size: 0.875rem;
    border: 1px solid #ccc;
    border-radius: 0.25rem;
    background: #f8f8f8;
    cursor: pointer;
  }
  .serve-retry:hover {
    background: #eee;
  }
  .serve-retry:focus-visible {
    outline: 2px solid #1e66f5;
    outline-offset: 2px;
  }
  :global(.project-section) {
    margin-bottom: 2rem;
  }
  :global(.project-name) {
    margin: 0 0 0.75rem;
    font-size: 1.25rem;
    font-weight: 600;
    padding-bottom: 0.25rem;
    border-bottom: 1px solid #eee;
  }
  :global(.project-cards) {
    display: grid;
    gap: 0.75rem;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, 260px), 1fr));
  }
  :global(.artifact-card) {
    display: block;
    padding: 0.85rem 1rem;
    border: 1px solid #e0e0e0;
    border-radius: 0.5rem;
    background: #fafafa;
    text-decoration: none;
    color: inherit;
    transition: border-color 0.12s ease, box-shadow 0.12s ease;
  }
  :global(.artifact-card:hover) {
    border-color: #1e66f5;
    box-shadow: 0 1px 4px rgba(0, 0, 0, 0.08);
  }
  :global(.artifact-card:focus-visible) {
    outline: 2px solid #1e66f5;
    outline-offset: 2px;
  }
  :global(.artifact-card-map) {
    background: #f4f6fb;
  }
  :global(.artifact-card-header) {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin-bottom: 0.4rem;
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  :global(.artifact-kind) {
    color: #1e66f5;
    font-weight: 600;
  }
  :global(.artifact-kind-map) {
    color: #8839ef;
  }
  :global(.artifact-status),
  :global(.artifact-diagram-kind) {
    color: #666;
    background: #eee;
    padding: 0.05rem 0.35rem;
    border-radius: 0.2rem;
    font-weight: 500;
  }
  :global(.artifact-title) {
    margin: 0 0 0.25rem;
    font-size: 0.95rem;
    font-weight: 600;
    color: #222;
    word-break: break-word;
  }
  :global(.artifact-relpath) {
    margin: 0 0 0.4rem;
    font-size: 0.8rem;
    color: #888;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  :global(.artifact-meta) {
    margin: 0;
    font-size: 0.75rem;
    color: #666;
  }
  :global(.artifact-meta-row) {
    display: flex;
    gap: 0.4rem;
  }
  :global(.artifact-meta dt) {
    font-weight: 500;
    color: #777;
  }
  :global(.artifact-meta dd) {
    margin: 0;
  }
  :global(.empty-state) {
    padding: 2rem 1rem;
    text-align: center;
    color: #666;
    border: 1px dashed #ccc;
    border-radius: 0.5rem;
  }
  @media (max-width: 600px) {
    .matcha-serve {
      padding: 1rem;
    }
    .serve-controls {
      flex-direction: column;
      align-items: stretch;
    }
    .serve-filter {
      justify-content: space-between;
    }
    :global(.project-cards) {
      grid-template-columns: 1fr;
    }
  }
</style>
