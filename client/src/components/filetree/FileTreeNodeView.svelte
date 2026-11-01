<script lang="ts">
  import type { FileTreeNode } from "../../../../src/plan.ts"
  import { computeChildPath } from "../../lib/fileTreeHelpers"

  export let node: FileTreeNode
  export let parentPath = ""
  export let depth = 0

  $: currentPath = computeChildPath(parentPath, node.name, node.path)
  $: isFolder = node.type === "folder"
</script>

{#if isFolder}
  <details class="folder" open data-depth={depth} data-path={currentPath}>
    <summary>
      <svg class="folder-icon" viewBox="0 0 20 20" width="16" height="16" aria-hidden="true">
        <path
          d="M2.5 5.5A1.5 1.5 0 0 1 4 4h4l2 2h6A1.5 1.5 0 0 1 17.5 7.5v8A1.5 1.5 0 0 1 16 17H4a1.5 1.5 0 0 1-1.5-1.5Z"
          fill="none"
          stroke="currentColor"
          stroke-width="1.4"
          stroke-linejoin="round"
        />
      </svg>
      <span class="folder-name">{node.name}</span>
    </summary>
    <div class="folder-children">
      {#each node.children ?? [] as child}
        <svelte:self node={child} parentPath={currentPath} depth={depth + 1} />
      {/each}
    </div>
  </details>
{:else}
  <div class="file-row" data-path={currentPath}>
    <code class="file-name" title={currentPath}>{node.name}</code>
    {#if node.status}
      <span class="file-status {node.status}">{node.status}</span>
    {/if}
    {#if node.stories && node.stories.length > 0}
      <span class="file-stories">
        {#each node.stories as storyId}
          <a href="#{storyId}" class="story-link"><code>{storyId}</code></a>
        {/each}
      </span>
    {/if}
  </div>
{/if}
