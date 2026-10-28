<script lang="ts">
  // Renders an AI summary (inbox group or thread) from the "- " bullet +
  // **bold** subset the prompts ask for — see summaryFormat.ts. Mixed
  // output (a bullet list plus a stray plain line) still renders: bullets
  // become list items, anything else a plain line.
  import { parseSummary } from "./summaryFormat";

  let { text }: { text: string } = $props();

  const lines = $derived(parseSummary(text));
  const allBullets = $derived(lines.length > 0 && lines.every((l) => l.bullet));
</script>

{#snippet inline(segments: { text: string; bold: boolean }[])}
  {#each segments as seg, i (i)}
    {#if seg.bold}<strong>{seg.text}</strong>{:else}{seg.text}{/if}
  {/each}
{/snippet}

{#if allBullets}
  <ul class="summary-list">
    {#each lines as line, i (i)}
      <li>{@render inline(line.segments)}</li>
    {/each}
  </ul>
{:else}
  {#each lines as line, i (i)}
    <div class="summary-line" class:is-bullet={line.bullet}>
      {@render inline(line.segments)}
    </div>
  {/each}
{/if}

<style>
  .summary-list {
    margin: 0;
    padding-left: 1.1em;
    list-style: disc;
  }
  .summary-list li {
    margin: 0;
    padding-left: 2px;
  }
  .summary-list li::marker {
    color: var(--text-tertiary);
  }
  .summary-line.is-bullet {
    padding-left: 1.1em;
    text-indent: -0.7em;
  }
  .summary-line.is-bullet::before {
    content: "\2022";
    display: inline-block;
    width: 0.7em;
    color: var(--text-tertiary);
  }
  strong {
    font-weight: 600;
    color: var(--text-primary);
  }
</style>
