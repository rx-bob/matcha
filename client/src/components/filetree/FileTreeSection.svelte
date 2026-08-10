<script lang="ts">
  import type { FileTree } from "../../../../src/plan.ts"
  import FileTreeNodeView from "./FileTreeNodeView.svelte"

  export let changedFiles: FileTree[]
</script>

<section class="document-section" id="changed-files">
  <header class="section-header">
    <h1 class="section-title">Changed Files</h1>
    <p class="page-subtitle">Files added or modified by this plan.</p>
  </header>

  {#each changedFiles as tree}
    <div class="ft-tree">
      {#if tree.label}
        <h2 class="ft-tree-label">{tree.label}</h2>
      {/if}
      <FileTreeNodeView node={tree.root} depth={0} />
    </div>
  {/each}
</section>

<style>
  .ft-tree {
    margin-bottom: 1.5rem;
  }

  .ft-tree:last-child {
    margin-bottom: 0;
  }

  .ft-tree-label {
    font-size: 1rem;
    font-weight: 700;
    color: var(--ink);
    margin: 0 0 0.5rem;
  }
</style>
