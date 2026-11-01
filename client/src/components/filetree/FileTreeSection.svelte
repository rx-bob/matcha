<script lang="ts">
  import type { FileTree } from "../../../../src/plan.ts"
  import FileTreeNodeView from "./FileTreeNodeView.svelte"
  import { buildFileIdMap, countFileStats } from "../../lib/fileTreeHelpers"

  export let changedFiles: FileTree[] = []

  $: stats = countFileStats(changedFiles)
  $: fileIds = buildFileIdMap(changedFiles)

  function handleExpandAll(): void {
    if (typeof document !== "undefined") {
      const folders = document.querySelectorAll<HTMLDetailsElement>("#view-files .folder")
      folders.forEach((f) => {
        f.open = true
      })
    }
  }

  function handleCollapseAll(): void {
    if (typeof document !== "undefined") {
      const folders = document.querySelectorAll<HTMLDetailsElement>("#view-files .folder")
      folders.forEach((f) => {
        f.open = f.dataset.depth === "0"
      })
    }
  }
</script>

<div class="files-toolbar">
  <span class="file-count">
    {stats.total} proposed files <span aria-hidden="true">·</span>
    {stats.newCount} new <span aria-hidden="true">·</span>
    {stats.modCount} modified
  </span>
  <div class="files-actions">
    <button type="button" data-expand-files on:click={handleExpandAll}>Expand all</button>
    <button type="button" data-collapse-files on:click={handleCollapseAll}>Collapse all</button>
  </div>
</div>

<div class="file-tree" aria-label="Proposed implementation files and mirrored tests">
  {#each changedFiles as tree}
    {#if tree.root}
      <FileTreeNodeView node={tree.root} parentPath="" depth={0} {fileIds} />
    {/if}
  {/each}
</div>
