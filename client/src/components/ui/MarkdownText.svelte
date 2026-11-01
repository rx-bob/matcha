<script lang="ts">
  import { renderMarkdown } from "../../lib/markdown"

  export let markdown: string

  $: renderedHtml = markdown ? renderMarkdown(markdown) : ""
</script>

{#if markdown}
  <div class="prose">{@html renderedHtml}</div>
{/if}
