<script lang="ts">
  // Square tiles keep the cat in the same orange mosaic style as the Chonk hero.
  const pixels = [
    "...oo......oo...",
    "...opo....opo...",
    "...oooaaaaooo...",
    "..ooaoooooaooo..",
    "..oaooooooooao..",
    "..oooXooooXooo..",
    "..ooooocoooooo..",
    "...ooocccoooo...",
    "..aooooccooooao.",
    ".oaoooccccoooao.",
    "ooaooccccccooaoo",
    "oaooccccccccooao",
    "ooocccccccccooao",
    "roocccccccccooro",
    ".roocccccccooroo",
    "..roooooooooroo.",
    "...rrrooorrrro..",
    "...ooo...ooo....",
  ]
  const palette: Record<string, string> = {
    o: "#ff641f",
    a: "#ff8200",
    r: "#f2361b",
    p: "#ff4b29",
    c: "#ffc078",
    X: "#29251f",
  }
</script>

<svg class="chonk-hero-art" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 420" aria-hidden="true" focusable="false">
  <g transform="rotate(-12 160 210)" shape-rendering="geometricPrecision" stroke="none">
    <!-- The curled tail peeks out from behind the very round belly. -->
    <path d="M268 294h36v-72h-18v54h-36v36h18z" fill="#f2361b" />
    <path d="M286 222h18v18h-18z" fill="#ff8200" />
    {#each pixels as row, y}
      {#each [...row] as pixel, x}
        {#if palette[pixel]}
          <rect x={16 + x * 18} y={48 + y * 18} width="18" height="18" fill={palette[pixel]} stroke={palette[pixel]} stroke-width=".25" />
        {/if}
      {/each}
    {/each}
    <!-- A small nose, sleepy eyes, and whiskers leave plenty of room for cat. -->
    <path d="M151 165h18v9h-18z" fill="#f2361b" />
    <path d="M151 183h9v9h-9zm9 0h9v9h-9z" fill="#29251f" />
    <path d="M43 156h27v6H43zm9 18h27v6H52zm198-18h27v6h-27zm-9 18h27v6h-27z" fill="#29251f" />
    <path d="M97 354v9m18-9v9m90-9v9m18-9v9" stroke="#f2361b" stroke-width="4" />
  </g>
</svg>
