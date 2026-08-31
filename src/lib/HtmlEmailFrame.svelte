<script lang="ts">
  // Renders (mock) HTML mail. sandbox without allow-scripts blocks JS but
  // allow-same-origin keeps the height measurable from the parent.
  // ponytail: no sanitization yet — mock data only; ammonia in the Rust core
  // must sanitize before real mail ever reaches this frame (DESIGN.md Security).
  let { html }: { html: string } = $props();

  let frame: HTMLIFrameElement | undefined = $state();

  function resize() {
    if (frame?.contentWindow) {
      try {
        frame.style.height = frame.contentWindow.document.documentElement.scrollHeight + "px";
      } catch {
        /* cross-origin — leave default height */
      }
    }
  }
</script>

<iframe
  bind:this={frame}
  srcdoc={html}
  onload={resize}
  sandbox="allow-same-origin"
  title="email content"
></iframe>

<style>
  iframe {
    width: 100%;
    border: none;
    display: block;
  }
</style>
