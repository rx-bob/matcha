<script lang="ts">
  import type { RecommendedOrderItem, Epic } from "../../../../src/plan"

  export let items: RecommendedOrderItem[] = []
  export let epics: Epic[] = []
  export let hidden = false

  function getTitle(ref: string): string {
    for (const epic of epics) {
      if (epic.id === ref) return epic.title
      if (epic.stories) {
        for (const story of epic.stories) {
          if (story.id === ref) return story.title
        }
      }
    }
    return ""
  }
</script>

<section class="page-view" id="view-order" data-view="order" {hidden}>
  <header class="page-heading">
    <h1>Optimal Order</h1>
  </header>

  <ol class="order-list">
    {#each items as item, index}
      <li class="order-step">
        <span class="step-number">{String(index + 1).padStart(2, "0")}</span>
        <div class="order-step-content">
          <a href="#{item.ref}" class="story-link">
            <code>{item.ref}</code>
            {#if getTitle(item.ref)}
              <span class="order-story-title">{getTitle(item.ref)}</span>
            {/if}
          </a>
          {#if item.reason}
            <p>{item.reason}</p>
          {/if}
        </div>
      </li>
    {/each}
  </ol>
</section>
