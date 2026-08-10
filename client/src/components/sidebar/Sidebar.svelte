<script lang="ts">
  import type { Plan } from "../../../../src/plan.ts"
  import { portal } from "../../lib/portal.ts"
  import { scrollToId } from "../../lib/ids.ts"
  import SidebarHeader from "./SidebarHeader.svelte"
  import NavItem from "./NavItem.svelte"
  import EpicNavGroup from "./EpicNavGroup.svelte"
  import SectionsNavGroup from "./SectionsNavGroup.svelte"
  import ThemePicker from "./ThemePicker.svelte"

  export let plan: Plan
  export let target: HTMLElement | null = null

  let activeId: string = "overview"
  let epicsGroup: HTMLElement
  let navScroll: HTMLElement

  function navigate(targetId: string): void {
    activeId = targetId
    scrollToId(targetId)
  }

  function toggleEpics(): void {
    epicsGroup.classList.toggle("nav-tree-collapsed")
  }

  $: sectionSummaries = (plan.sections ?? []).map((s) => ({ id: s.id, title: s.title }))
</script>

<div class="sidebar-shell" use:portal={target}>
  <SidebarHeader title={plan.title} />

  <div class="sidebar-scroll" bind:this={navScroll}>
    <NavItem
    targetId="overview"
    label="Overview"
    active={activeId === "overview"}
    depth={0}
    on:navigate={(event) => navigate(event.detail)}
  />

  {#if plan.changedFiles && plan.changedFiles.length > 0}
    <NavItem
      targetId="changed-files"
      label="Changed Files"
      active={activeId === "changed-files"}
      depth={0}
      on:navigate={(event) => navigate(event.detail)}
    />
  {/if}

  <div bind:this={epicsGroup} class="nav-tree-group nav-depth-0 nav-tree-section">
    <div class="nav-tree-row">
      <button
        class="nav-disclosure"
        type="button"
        aria-expanded="true"
        aria-label="Collapse Epics"
        on:click={toggleEpics}
      >
        <span class="disclosure-icon">-</span>
      </button>
      <div class="sidebar-heading sidebar-heading-button nav-tree-label">Epics</div>
    </div>
    <div class="nav-tree-children">
      {#each plan.epics ?? [] as epic}
        <EpicNavGroup {epic} {activeId} on:navigate={(event) => navigate(event.detail)} />
      {/each}
    </div>
  </div>

  <div class="sidebar-heading">Plan</div>

  {#if sectionSummaries.length > 0}
    <SectionsNavGroup sections={sectionSummaries} {activeId} on:navigate={(event) => navigate(event.detail)} />
  {/if}

  <NavItem
    targetId="workflows"
    label="Workflows"
    active={activeId === "workflows"}
    depth={0}
    on:navigate={(event) => navigate(event.detail)}
  />
  <NavItem
    targetId="commands"
    label="Commands"
    active={activeId === "commands"}
    depth={0}
    on:navigate={(event) => navigate(event.detail)}
  />
  <NavItem
    targetId="recommended-order"
    label="Recommended Order"
    active={activeId === "recommended-order"}
    depth={0}
    on:navigate={(event) => navigate(event.detail)}
  />
  <NavItem
    targetId="exit-criteria"
    label="Exit Criteria"
    active={activeId === "exit-criteria"}
    depth={0}
    on:navigate={(event) => navigate(event.detail)}
  />
  </div>

  <div class="sidebar-footer">
    <ThemePicker />
  </div>
</div>

<style>
  .sidebar-shell {
    display: grid;
    grid-template-rows: auto 1fr auto;
    height: 100%;
    min-height: 100%;
  }

  .sidebar-scroll {
    overflow-y: auto;
    min-height: 0;
  }

  .sidebar-footer {
    border-top: 1px solid var(--line);
    background: var(--paper);
  }
</style>
