<script lang="ts">
  import type { Plan } from "../../../../src/plan"
  import { buildFileIdMap } from "../../lib/fileTreeHelpers"
  import {
    MAX_SEARCH_RESULTS,
    buildSearchIndex,
    filterSearch,
    highlightSegments,
    suggestedItems,
  } from "../../lib/search"

  export let plan: Plan

  let dialog: HTMLDialogElement
  let input: HTMLInputElement
  let results: HTMLElement
  let query = ""

  $: index = buildSearchIndex(plan, buildFileIdMap(plan.changedFiles ?? []))
  $: trimmed = query.trim()
  $: found = trimmed ? filterSearch(index, trimmed) : suggestedItems(index)
  $: shown = found.slice(0, MAX_SEARCH_RESULTS)
  $: countLabel = !trimmed
    ? "Suggested destinations"
    : found.length > shown.length
      ? `Showing ${shown.length} of ${found.length} results`
      : `${found.length} result${found.length === 1 ? "" : "s"}`

  export function isOpen(): boolean {
    return Boolean(dialog?.open)
  }

  export function open(): void {
    if (!dialog) return
    query = ""
    if (!dialog.open) dialog.showModal()
    input?.focus()
  }

  export function close(): void {
    if (dialog?.open) dialog.close()
  }

  export function toggle(): void {
    if (isOpen()) close()
    else open()
  }

  function resultLinks(): HTMLAnchorElement[] {
    return Array.from(results.querySelectorAll<HTMLAnchorElement>(".search-result"))
  }

  function onKeydown(event: KeyboardEvent): void {
    const links = resultLinks()
    if (links.length === 0) return
    const current = links.indexOf(document.activeElement as HTMLAnchorElement)

    if (event.key === "ArrowDown") {
      event.preventDefault()
      links[(current + 1) % links.length].focus()
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      if (current <= 0) input.focus()
      else links[current - 1].focus()
    } else if (event.key === "Enter" && document.activeElement === input) {
      event.preventDefault()
      links[0].click()
    }
  }

  function onDialogClick(event: MouseEvent): void {
    if (event.target === dialog) close()
  }

  // Close before the delegated router handler navigates, so focus lands on the target.
  function onResultsClick(event: MouseEvent): void {
    if ((event.target as HTMLElement | null)?.closest(".search-result")) close()
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
<dialog
  class="search-dialog"
  id="search-dialog"
  aria-label="Search implementation plan"
  bind:this={dialog}
  on:keydown={onKeydown}
  on:click={onDialogClick}
>
  <div class="search-field">
    <svg aria-hidden="true"><use href="#i-search" /></svg>
    <input
      type="search"
      id="global-search"
      aria-label="Search stories, files, and references"
      placeholder="Search stories, files, and references…"
      autocomplete="off"
      bind:this={input}
      bind:value={query}
    />
    <button id="close-search" aria-label="Close search" on:click={close}>esc</button>
  </div>
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="search-results" id="search-results" bind:this={results} on:click={onResultsClick}>
    {#if shown.length}
      {#each shown as item (item.kind + item.id)}
        <a class="search-result" href={`#${encodeURIComponent(item.id)}`}>
          <code>{item.label}</code>
          <span>
            <strong>{#each highlightSegments(item.title, trimmed) as segment}{#if segment.match}<mark>{segment.text}</mark>{:else}{segment.text}{/if}{/each}</strong>
            <small>{item.info}</small>
          </span>
        </a>
      {/each}
    {:else}
      <div class="search-empty">No results for this search. Try a story ID, file name, or keyword.</div>
    {/if}
  </div>
  <div class="search-hint">
    <span id="search-result-count">{countLabel}</span><span>↑ ↓ navigate · esc close</span>
  </div>
</dialog>
