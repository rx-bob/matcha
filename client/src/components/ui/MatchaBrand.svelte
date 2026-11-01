<script lang="ts">
  import mascot from "../../../../assets/mascot_mono_light_bg.png?inline"
</script>

<a href="#overview" class="brand" aria-label="Matcha — plan overview">
  <span class="brandmark" aria-hidden="true">
    <span class="matcha-mascot" style={`--mascot: url("${mascot}")`}></span>
  </span>
</a>

<style>
  .brand {
    min-height: 84px;
    justify-content: center;
  }

  .brandmark {
    flex-shrink: 0;
    display: grid;
    place-items: center;
  }

  .matcha-mascot {
    display: block;
    width: 80px;
    height: 80px;
    background: currentColor;
    mask: var(--mascot) center / contain no-repeat;
    -webkit-mask: var(--mascot) center / contain no-repeat;
  }

  :global(:root[data-design="coral"]) .brandmark {
    width: 84px;
    height: 84px;
    border: 0;
    border-radius: 0;
    background: transparent;
    color: #e33920;
  }

  :global(:root[data-design="chonk"]) .brandmark {
    width: 84px;
    height: 84px;
    border: 0;
    border-radius: 0;
    background: transparent;
    color: var(--accent);
  }

  :global(:root[data-design="eva-01"]) .brandmark {
    width: 84px;
    height: 84px;
    border: 0;
    border-radius: 0;
    background: transparent;
  }
</style>
