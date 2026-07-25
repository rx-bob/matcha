<script lang="ts">
  import type { ProjectDisplay } from "../../lib/catalog.ts"
  import ArtifactCard from "./ArtifactCard.svelte"

  export let project: ProjectDisplay
</script>

<section class="project-section" aria-labelledby={`project-${project.name}`}>
  <h2 id={`project-${project.name}`} class="project-name">{project.name}</h2>
  <div class="project-cards">
    {#each project.artifacts as artifact (artifact.url)}
      <ArtifactCard {artifact} />
    {/each}
  </div>
</section>
