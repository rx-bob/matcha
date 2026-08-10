<script lang="ts">
  import type { FileTreeNode, FileNodeStatus } from "../../../../src/plan.ts"
  import { Folder, FolderOpen, File, ChevronRight, ChevronDown } from "@lucide/svelte"

  export let node: FileTreeNode
  export let depth: number = 0

  let collapsed = false

  function toggle() {
    collapsed = !collapsed
  }

  function hasStatusInChildren(node: FileTreeNode): boolean {
    for (const child of node.children ?? []) {
      if (child.status) return true
      if (child.type === "folder" && hasStatusInChildren(child)) return true
    }
    return false
  }

  function statusBadgeClass(status: FileNodeStatus | undefined): string {
    if (status === "new") return "ft-badge ft-badge-new"
    if (status === "modified") return "ft-badge ft-badge-modified"
    return ""
  }

  function statusLabel(status: FileNodeStatus | undefined): string {
    if (status === "new") return "A"
    if (status === "modified") return "M"
    return ""
  }

  $: isFolder = node.type === "folder"
  $: showDescendantDot = isFolder && !collapsed && hasStatusInChildren(node)
</script>

<div class="ft-node" style="--ft-depth: {depth}">
  {#if isFolder}
    <div
      class="ft-row ft-folder-row"
      role="button"
      tabindex="0"
      aria-expanded={!collapsed}
      on:click={toggle}
      on:keydown={(e) => e.key === "Enter" || e.key === " " ? toggle() : null}
    >
      <span class="ft-toggle">
        {#if collapsed}
          <ChevronRight size={14} />
        {:else}
          <ChevronDown size={14} />
        {/if}
      </span>
      <span class="ft-icon ft-icon-folder">
        {#if collapsed}
          <Folder size={16} />
        {:else}
          <FolderOpen size={16} />
        {/if}
      </span>
      <span class="ft-name">{node.name}</span>
      {#if hasStatusInChildren(node)}
        <span class="ft-descendant-dot" title="contains changes"></span>
      {/if}
    </div>
    {#if !collapsed}
      <div class="ft-children">
        {#each node.children ?? [] as child}
          <svelte:self node={child} depth={depth + 1} />
        {/each}
      </div>
    {/if}
  {:else}
    <div class="ft-row ft-file-row">
      <span class="ft-toggle ft-toggle-leaf"></span>
      <span class="ft-icon ft-icon-file">
        <File size={16} />
      </span>
      <span class="ft-name">{node.name}</span>
      {#if node.status}
        <span class={statusBadgeClass(node.status)}>{statusLabel(node.status)}</span>
      {/if}
    </div>
  {/if}
</div>

<style>
  .ft-node {
    --ft-indent: 1.25rem;
  }

  .ft-row {
    display: flex;
    align-items: center;
    gap: 0.375rem;
    padding-left: calc(var(--ft-depth) * var(--ft-indent));
    min-height: 1.75rem;
    cursor: default;
    user-select: none;
    border-radius: 0.25rem;
  }

  .ft-folder-row {
    cursor: pointer;
  }

  .ft-folder-row:hover {
    background: var(--soft);
  }

  .ft-folder-row:focus-visible {
    outline: 2px solid var(--primary);
    outline-offset: -2px;
  }

  .ft-toggle {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 1rem;
    height: 1rem;
    flex-shrink: 0;
    color: var(--subtle);
  }

  .ft-toggle-leaf {
    width: 1rem;
    flex-shrink: 0;
  }

  .ft-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  .ft-icon-folder {
    color: var(--primary);
  }

  .ft-icon-file {
    color: var(--muted);
  }

  .ft-name {
    font-size: 0.8125rem;
    color: var(--ink);
    white-space: nowrap;
  }

  .ft-folder-row .ft-name {
    font-weight: 600;
  }

  .ft-file-row .ft-name {
    font-weight: 400;
  }

  .ft-descendant-dot {
    display: inline-block;
    width: 0.4rem;
    height: 0.4rem;
    border-radius: 50%;
    background: var(--primary);
    margin-left: 0.25rem;
    flex-shrink: 0;
  }

  .ft-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 0.625rem;
    font-weight: 700;
    border-radius: 0.25rem;
    padding: 0.05rem 0.3rem;
    line-height: 1.4;
    margin-left: 0.25rem;
    flex-shrink: 0;
  }

  .ft-badge-new {
    background: color-mix(in srgb, var(--primary) 18%, transparent);
    color: var(--primary);
    border: 1px solid color-mix(in srgb, var(--primary) 35%, transparent);
  }

  .ft-badge-modified {
    background: color-mix(in srgb, var(--muted) 18%, transparent);
    color: var(--muted);
    border: 1px solid color-mix(in srgb, var(--muted) 35%, transparent);
  }

  .ft-children {
    /* children rendered with own depth via svelte:self */
  }
</style>
