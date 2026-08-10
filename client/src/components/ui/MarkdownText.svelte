<script lang="ts">
  import { marked } from "marked"

  export let markdown: string

  $: renderedHtml = marked.parse(markdown, { async: false }) as string
</script>

{#if markdown}
  <div class="markdown-text">{@html renderedHtml}</div>
{/if}

<style>
  .markdown-text {
    max-width: 64rem;
    color: var(--muted);
    font-size: 0.875rem;
    line-height: 1.6;
  }

  .markdown-text :global(h1),
  .markdown-text :global(h2),
  .markdown-text :global(h3),
  .markdown-text :global(h4),
  .markdown-text :global(h5),
  .markdown-text :global(h6) {
    margin: 1.25rem 0 0.5rem;
    color: var(--ink);
    font-weight: 700;
    line-height: 1.3;
  }

  .markdown-text :global(h1) {
    font-size: 1.5rem;
  }

  .markdown-text :global(h2) {
    font-size: 1.25rem;
  }

  .markdown-text :global(h3) {
    font-size: 1.125rem;
  }

  .markdown-text :global(h4),
  .markdown-text :global(h5),
  .markdown-text :global(h6) {
    font-size: 1rem;
  }

  .markdown-text :global(p) {
    margin: 0 0 0.75rem;
  }

  .markdown-text :global(p:last-child) {
    margin-bottom: 0;
  }

  .markdown-text :global(ul),
  .markdown-text :global(ol) {
    margin: 0 0 0.75rem;
    padding-left: 1.5rem;
  }

  .markdown-text :global(ul) {
    list-style: disc;
  }

  .markdown-text :global(ol) {
    list-style: decimal;
  }

  .markdown-text :global(li) {
    margin: 0.25rem 0;
  }

  .markdown-text :global(li:last-child) {
    margin-bottom: 0;
  }

  .markdown-text :global(li > ul),
  .markdown-text :global(li > ol) {
    margin-top: 0.25rem;
    margin-bottom: 0;
  }

  .markdown-text :global(code) {
    border-radius: 0.25rem;
    background: var(--soft);
    padding: 0.1rem 0.25rem;
    font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace;
    font-size: 0.8125rem;
  }

  .markdown-text :global(pre) {
    margin: 0 0 0.75rem;
    border-radius: 0.375rem;
    background: var(--matcha-surface1, #0f172a);
    color: var(--matcha-text, white);
    padding: 0.75rem;
    overflow-x: auto;
    white-space: pre-wrap;
  }

  .markdown-text :global(pre code) {
    background: none;
    padding: 0;
    color: inherit;
    font-size: 0.8125rem;
    white-space: pre-wrap;
  }

  .markdown-text :global(blockquote) {
    margin: 0 0 0.75rem;
    border-left: 3px solid var(--line);
    padding-left: 1rem;
    color: var(--subtle);
  }

  .markdown-text :global(a) {
    color: var(--primary);
    text-decoration: none;
  }

  .markdown-text :global(a:hover) {
    text-decoration: underline;
  }

  .markdown-text :global(strong) {
    color: var(--ink);
    font-weight: 700;
  }

  .markdown-text :global(hr) {
    margin: 1rem 0;
    border: 0;
    border-top: 1px solid var(--line);
  }

  .markdown-text :global(table) {
    width: 100%;
    margin: 0 0 0.75rem;
    border-collapse: collapse;
    font-size: 0.8125rem;
  }

  .markdown-text :global(th),
  .markdown-text :global(td) {
    border: 1px solid var(--line);
    padding: 0.4rem 0.6rem;
    text-align: left;
    vertical-align: top;
  }

  .markdown-text :global(th) {
    background: var(--soft);
    font-weight: 700;
  }
</style>
