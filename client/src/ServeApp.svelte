<script lang="ts">
  import { onMount } from "svelte"
  import {
    isEmptyCatalog,
    parseCatalog,
    toProjectDisplays,
    totalArtifactCount,
    type ProjectDisplay,
  } from "./lib/catalog.ts"
  import ProjectSection from "./components/serve/ProjectSection.svelte"
  import EmptyState from "./components/serve/EmptyState.svelte"

  export let catalogUrl: string

  type LoadState = "loading" | "loaded" | "error"
  let state: LoadState = "loading"
  let errorMessage = ""
  let projects: ProjectDisplay[] = []
  let warningCount = 0

  async function refreshCatalog(): Promise<void> {
    try {
      const response = await fetch(catalogUrl, {
        headers: { Accept: "application/json" },
      })
      if (!response.ok) {
        state = "error"
        errorMessage = `Server returned ${response.status} ${response.statusText}`.trim()
        return
      }
      const json: unknown = await response.json()
      const catalog = parseCatalog(json)
      projects = toProjectDisplays(catalog)
      warningCount = catalog.warnings.length
      state = "loaded"
    } catch (err) {
      state = "error"
      errorMessage = err instanceof Error ? err.message : "Catalog request failed"
    }
  }

  onMount(() => {
    void refreshCatalog()
  })

  $: totalArtifacts =
    state === "loaded" ? projects.reduce((sum, p) => sum + p.artifacts.length, 0) : 0
  $: showEmpty = state === "loaded" && totalArtifacts === 0
</script>

<main class="matcha-serve">
  <header class="serve-header">
    <h1>matcha serve</h1>
    {#if state === "loaded" && totalArtifacts > 0}
      <p class="serve-summary">
        {totalArtifacts} artifact{totalArtifacts === 1 ? "" : "s"}
        {#if warningCount > 0}
          <span class="serve-warnings">({warningCount} warning{warningCount === 1 ? "" : "s"})</span>
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
  {:else}
    {#each projects as project (project.name)}
      {#if project.artifacts.length > 0}
        <ProjectSection {project} />
      {/if}
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
    margin: 0 0 0.25rem;
    font-size: 1.75rem;
    font-weight: 600;
  }
  .serve-summary {
    margin: 0;
    color: #666;
    font-size: 0.875rem;
  }
  .serve-warnings {
    margin-left: 0.5rem;
    color: #b8860b;
  }
  .serve-loading,
  .serve-error {
    padding: 1rem 0;
    font-size: 0.95rem;
  }
  .serve-error {
    color: #b22222;
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
    :global(.project-cards) {
      grid-template-columns: 1fr;
    }
  }
</style>
