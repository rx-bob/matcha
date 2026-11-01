<script lang="ts">
  function close(): void {
    const dialog = document.getElementById("copy-dialog") as HTMLDialogElement | null
    dialog?.close()
  }
</script>

<dialog class="copy-dialog" id="copy-dialog" aria-labelledby="copy-title">
  <h2 id="copy-title">Copy reference</h2>
  <p>Select and copy the text below.</p>
  <textarea id="copy-text" readonly aria-label="Text to copy"></textarea>
  <button class="btn" id="close-copy" on:click={close}>Done</button>
</dialog>
