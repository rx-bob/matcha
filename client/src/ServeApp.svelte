<script lang="ts">
  export let catalogUrl: string
</script>

<main class="matcha-serve">
  <h1>matcha serve</h1>
  <p>Loading catalog from <code>{catalogUrl}</code>&hellip;</p>
</main>

<style>
  .matcha-serve {
    font-family: system-ui, sans-serif;
    max-width: 960px;
    margin: 0 auto;
    padding: 1.5rem;
    color: #333;
  }
  .matcha-serve h1 {
    margin-bottom: 0.5rem;
  }
  .matcha-serve code {
    background: #f4f4f4;
    padding: 0.1rem 0.25rem;
    border-radius: 0.25rem;
  }
</style>
