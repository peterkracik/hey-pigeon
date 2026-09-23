<script lang="ts">
  import type { BackendTriageLabel } from "./ipc";

  // Small expand icon next to the folder title, hidden by default — opens
  // a horizontal row of Jev triage labels (Superhuman-style subtitle tabs)
  // so the list can be narrowed to one category. The folder title itself
  // is the implicit "no filter" tab; clicking it (App.svelte) clears
  // whatever is selected here.
  let {
    labels,
    activeId,
    onSelect,
  }: {
    labels: BackendTriageLabel[];
    activeId: string | null;
    onSelect: (id: string | null) => void;
  } = $props();

  let open = $state(false);
</script>

{#if labels.length > 0}
  <div class="root">
    {#if open}
      <div class="tabs">
        {#each labels as l (l.id)}
          <button
            class="tab"
            class:active={activeId === l.id}
            onclick={(ev) => {
              ev.stopPropagation();
              onSelect(activeId === l.id ? null : l.id);
            }}
          >
            {l.name}
          </button>
        {/each}
      </div>
    {/if}
    <button
      class="trigger"
      class:active={activeId !== null}
      title={open ? "Hide Jev labels" : "Show Jev labels"}
      aria-label={open ? "Hide Jev labels" : "Show Jev labels"}
      aria-expanded={open}
      onclick={(ev) => {
        ev.stopPropagation();
        open = !open;
      }}
    >
      <svg class="chevron" class:open width="11" height="11" viewBox="0 0 24 24" fill="none">
        <path d="M9 6l6 6-6 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
  </div>
{/if}

<style>
  .root {
    display: flex;
    align-items: baseline;
    gap: 12px;
    min-width: 0;
  }
  .trigger {
    display: flex;
    align-items: center;
    justify-content: center;
    align-self: center;
    width: 18px;
    height: 18px;
    border: none;
    background: none;
    cursor: pointer;
    padding: 0;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }
  .trigger:hover,
  .trigger.active {
    color: var(--text-secondary);
  }
  .chevron {
    transition: transform 160ms;
  }
  .chevron.open {
    transform: rotate(180deg);
  }
  .tabs {
    display: flex;
    align-items: baseline;
    gap: 14px;
    overflow-x: auto;
    scrollbar-width: none;
    min-width: 0;
  }
  .tabs::-webkit-scrollbar {
    display: none;
  }
  .tab {
    border: none;
    background: none;
    cursor: pointer;
    padding: 0;
    white-space: nowrap;
    font-family: var(--font-body);
    font-weight: 400;
    font-size: 13px;
    color: var(--text-tertiary);
    transition: color var(--duration-fast) var(--ease-standard);
  }
  .tab:hover {
    color: var(--text-secondary);
  }
  .tab.active {
    color: var(--text-primary);
    font-weight: 600;
  }
</style>
