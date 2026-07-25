<script lang="ts">
  import type { ArtifactDisplay } from "../../lib/catalog.ts"

  export let artifact: ArtifactDisplay
</script>

<a
  class="artifact-card"
  class:artifact-card-map={artifact.kind === "map"}
  href={artifact.url}
  aria-label={`${artifact.kind === "map" ? "Map" : "Plan"}: ${artifact.title}`}
>
  <div class="artifact-card-header">
    <span class="artifact-kind" class:artifact-kind-map={artifact.kind === "map"}>
      {artifact.kind === "map" ? "Map" : "Plan"}
    </span>
    {#if artifact.status}
      <span class="artifact-status">{artifact.status}</span>
    {/if}
    {#if artifact.diagramKind}
      <span class="artifact-diagram-kind">{artifact.diagramKind}</span>
    {/if}
  </div>
  <h3 class="artifact-title">{artifact.title}</h3>
  <p class="artifact-relpath" title={artifact.relPath}>{artifact.filename}</p>
  <dl class="artifact-meta">
    {#if artifact.generatedAt}
      <div class="artifact-meta-row">
        <dt>Generated</dt>
        <dd>{artifact.generatedAt}</dd>
      </div>
    {/if}
    {#if artifact.mtime}
      <div class="artifact-meta-row">
        <dt>Modified</dt>
        <dd>{artifact.mtime}</dd>
      </div>
    {/if}
  </dl>
</a>
