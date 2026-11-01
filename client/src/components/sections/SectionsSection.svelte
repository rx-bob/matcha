<script lang="ts">
  import type { PlanSection } from "../../../../src/plan"

  export let sections: PlanSection[] = []
  export let hidden = false
</script>

<section class="page-view" id="view-context" data-view="context" {hidden}>
  <header class="page-heading">
    <h1>Decisions &amp; architecture</h1>
  </header>

  {#each sections as section}
    <article class="context-card" id={section.id}>
      <span id="section-{section.id}" class="legacy-anchor"></span>
      <div class="context-header context-card-header">
        <h2>{section.title}</h2>
        {#if section.kind}
          <span class="context-kind">{section.kind}</span>
        {/if}
      </div>
      {#if section.summary}
        <p class="context-summary">{section.summary}</p>
      {/if}
      <div class="context-items">
        {#each section.items || [] as item}
          <div class="context-item">
            {#if item.title}
              <h3 class="context-item-title">{item.title}</h3>
            {/if}
            <p class="context-item-text">{item.text}</p>
          </div>
        {/each}
      </div>
    </article>
  {/each}
</section>
