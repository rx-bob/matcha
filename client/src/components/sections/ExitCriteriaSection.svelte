<script lang="ts">
  export let criteria: string[] = []
  export let hidden = false
</script>

<section class="page-view" id="view-criteria" data-view="criteria" {hidden}>
  <header class="page-heading">
    <h1>Release criteria</h1>
  </header>

  <ol class="criteria-list">
    {#each criteria as criterion, index}
      <li>
        <span class="criterion-number">{String(index + 1).padStart(2, "0")}</span>
        <p>{criterion}</p>
      </li>
    {/each}
  </ol>
</section>
