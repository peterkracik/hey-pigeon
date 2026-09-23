<script lang="ts">
  import type { BackendTriageLabel } from "./ipc";

  // Jev label-name pills — shared by InboxList's open-preview footer and
  // ThreadView's full-thread header. Priority lives in the separate
  // PriorityIndicator (rendered alongside this by callers).
  let {
    labelIds,
    triageLabels,
    onToggleLabel,
  }: {
    labelIds: string[] | undefined;
    triageLabels: BackendTriageLabel[];
    /** Provide to make badges editable: a "+" menu to add a label, and a
     *  "×" on each badge to remove it. Omit for read-only display. */
    onToggleLabel?: (labelId: string) => void;
  } = $props();

  let menuOpen = $state(false);
  let root: HTMLDivElement | undefined = $state();
  let btnEl: HTMLButtonElement | undefined = $state();
  // Fixed-viewport coords, not CSS position:absolute — the badges row lives
  // inside cards with `overflow: hidden` (rounded-corner clipping), which
  // would otherwise clip the menu invisible instead of just repositioning it.
  let menuPos = $state({ top: 0, left: 0 });

  function onDocMousedown(ev: MouseEvent) {
    if (menuOpen && root && !root.contains(ev.target as Node)) menuOpen = false;
  }

  function toggleMenu() {
    if (!menuOpen && btnEl) {
      const r = btnEl.getBoundingClientRect();
      menuPos = { top: r.bottom + 6, left: r.left };
    }
    menuOpen = !menuOpen;
  }

  const applied = $derived(new Set(labelIds ?? []));
</script>

<svelte:document onmousedown={onDocMousedown} />

{#each labelIds ?? [] as id (id)}
  {@const name = triageLabels.find((l) => l.id === id)?.name}
  {#if name}
    <span class="triage-badge">
      {name}
      {#if onToggleLabel}
        <button
          type="button"
          class="badge-x"
          aria-label="Remove {name}"
          onclick={(ev) => {
            ev.stopPropagation();
            onToggleLabel?.(id);
          }}
        >
          <svg width="9" height="9" viewBox="0 0 24 24" fill="none">
            <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" />
          </svg>
        </button>
      {/if}
    </span>
  {/if}
{/each}
{#if onToggleLabel}
  <div bind:this={root} class="add-root">
    <button
      type="button"
      bind:this={btnEl}
      class="add-btn"
      aria-label="Add label"
      title="Add label"
      onclick={(ev) => {
        ev.stopPropagation();
        toggleMenu();
      }}
    >
      <svg width="10" height="10" viewBox="0 0 24 24" fill="none">
        <path d="M12 5v14M5 12h14" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" />
      </svg>
    </button>
    {#if menuOpen}
      <div class="add-menu" style:top="{menuPos.top}px" style:left="{menuPos.left}px" role="menu">
        {#each triageLabels as l (l.id)}
          <button
            type="button"
            class="add-item"
            class:checked={applied.has(l.id)}
            onclick={(ev) => {
              ev.stopPropagation();
              onToggleLabel?.(l.id);
            }}
          >
            <span class="check">{applied.has(l.id) ? "✓" : ""}</span>
            {l.name}
          </button>
        {/each}
        {#if triageLabels.length === 0}
          <span class="add-empty">No labels yet — add some in Settings → Triage.</span>
        {/if}
      </div>
    {/if}
  </div>
{/if}

<style>
  .triage-badge {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 9px;
    border-radius: var(--radius-pill);
    background: var(--surface-sunken);
    font-family: var(--font-body);
    font-size: 11.5px;
    font-weight: 600;
    color: var(--text-secondary);
    white-space: nowrap;
  }
  .badge-x {
    display: flex;
    border: none;
    background: none;
    cursor: pointer;
    padding: 0;
    color: inherit;
    opacity: 0.6;
  }
  .badge-x:hover {
    opacity: 1;
  }
  .add-root {
    position: relative;
    display: inline-flex;
  }
  .add-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    border: 1px dashed var(--border-default);
    background: none;
    cursor: pointer;
    padding: 0;
    color: var(--text-tertiary);
    box-sizing: border-box;
  }
  .add-btn:hover {
    color: var(--text-secondary);
    border-color: var(--text-secondary);
  }
  .add-menu {
    position: fixed;
    background: var(--surface-card);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
    z-index: 50;
    padding: 6px;
    display: flex;
    flex-direction: column;
    min-width: 160px;
    max-width: 240px;
  }
  .add-item {
    display: flex;
    align-items: center;
    gap: 8px;
    border: none;
    background: none;
    cursor: pointer;
    padding: 6px 8px;
    border-radius: var(--radius-md);
    text-align: left;
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-primary);
    white-space: nowrap;
  }
  .add-item:hover {
    background: var(--surface-hover);
  }
  .check {
    width: 12px;
    flex-shrink: 0;
    color: var(--tag-mint-fg, var(--text-primary));
    font-size: 11px;
  }
  .add-empty {
    font-family: var(--font-body);
    font-size: 12px;
    color: var(--text-tertiary);
    padding: 4px 6px;
  }
</style>
