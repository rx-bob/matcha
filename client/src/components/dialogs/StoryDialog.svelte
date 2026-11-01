<dialog class="story-dialog" id="story-dialog" aria-labelledby="story-dialog-title">
  <header class="story-dialog-header">
    <div class="story-dialog-heading">
      <div class="story-dialog-meta">
        <code id="story-dialog-id"></code>
        <span id="story-dialog-risk" class="risk-badge"></span>
      </div>
      <h2 id="story-dialog-title" tabindex="-1"></h2>
    </div>
    <button type="button" id="close-story" class="story-dialog-close" aria-label="Close story">
      <svg aria-hidden="true"><use href="#i-close" /></svg>
    </button>
  </header>
  <div id="story-dialog-content" class="story-dialog-content"></div>
  <div
    id="story-dialog-feedback"
    class="story-dialog-feedback"
    role="status"
    aria-live="polite"
    hidden
  ></div>
</dialog>
