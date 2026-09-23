<script lang="ts">
  import Tooltip from "./ds/Tooltip.svelte";

  // Shared by InboxList (list row + open-preview footer) and ThreadView
  // (full-thread header) — one Jev priority indicator, one place to change
  // how it looks.
  let {
    priority,
  }: {
    priority?: "spam" | "low" | "medium" | "high";
  } = $props();
</script>

{#if priority === "spam"}
  <Tooltip label="Likely spam or junk" side="top">
    <span class="priority-spam">
      <svg width="9" height="9" viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="2.5" />
        <line x1="5.5" y1="18.5" x2="18.5" y2="5.5" stroke="currentColor" stroke-width="2.5" />
      </svg>
    </span>
  </Tooltip>
{:else if priority}
  {@const level = priority === "high" ? 3 : priority === "medium" ? 2 : 1}
  <Tooltip label="Priority: {priority}" side="top">
    <span class="priority-bars" class:p-high={priority === "high"}>
      {#each [1, 2, 3] as bar (bar)}
        <span class="bar" class:filled={bar > 3 - level}></span>
      {/each}
    </span>
  </Tooltip>
{/if}

<style>
  /* Jev triage priority — 3-bar indicator (hamburger-menu shape, narrower):
     1 bar lit = low, 2 = medium, 3 = high. High also switches to the same
     alert color as overdue reminders. Spam gets a distinct muted "blocked"
     icon instead of an empty/0-bar state, which would look identical to
     "no priority at all". */
  .priority-bars {
    flex-shrink: 0;
    display: inline-flex;
    flex-direction: column;
    justify-content: center;
    gap: 1.5px;
    width: 9px;
  }
  .priority-bars .bar {
    height: 1.5px;
    border-radius: 1px;
    background: var(--border-default);
  }
  .priority-bars .bar.filled {
    background: var(--tag-amber-fg);
  }
  .priority-bars.p-high .bar.filled {
    background: var(--tag-coral-fg);
  }
  .priority-spam {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-tertiary);
  }
</style>
