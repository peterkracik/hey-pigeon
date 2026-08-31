<script lang="ts">
  let {
    open,
    onClose,
    onAction,
  }: {
    open: boolean;
    onClose: () => void;
    onAction: (key: string) => void;
  } = $props();

  const COMMANDS = [
    { key: "done", label: "Mark done", shortcut: "E", d: "M20 6L9 17l-5-5" },
    { key: "remind", label: "Remind me", shortcut: "H", d: "M12 7v5l3 3M12 22a10 10 0 100-20 10 10 0 000 20z" },
    { key: "star", label: "Star", shortcut: "S", d: "M12 3l2.6 5.6 6.1.6-4.6 4.1 1.3 6-5.4-3.1-5.4 3.1 1.3-6-4.6-4.1 6.1-.6z" },
    { key: "move", label: "Move to folder", shortcut: "V", d: "M3 7l9 6 9-6M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1z" },
    { key: "label", label: "Add label", shortcut: "L", d: "M20.6 12.3l-8-8A2 2 0 0011.2 3.7L4 4v7.2a2 2 0 00.6 1.4l8 8a2 2 0 002.8 0l5.2-5.2a2 2 0 000-2.8zM8 8h.01" },
    { key: "reply", label: "Reply", shortcut: "R", d: "M9 17l-5-5 5-5M4 12h11a5 5 0 010 10h-1" },
    { key: "forward", label: "Forward", shortcut: "F", d: "M15 17l5-5-5-5M20 12H9a5 5 0 000 10h1" },
    { key: "compose", label: "Compose new message", shortcut: "C", d: "M4 20l1-4L17 4l3 3L8 19l-4 1z" },
    { key: "inbox", label: "Go to Inbox", shortcut: "G I", d: "M3 12l9-9 9 9M5 10v10h14V10" },
    { key: "unified", label: "Go to All Inboxes", shortcut: "G U", d: "M3 3h8v8H3zM13 3h8v8h-8zM3 13h8v8H3zM13 13h8v8h-8z" },
    { key: "delete", label: "Delete", shortcut: "#", d: "M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13" },
  ];

  let query = $state("");
  let index = $state(0);
  let inputEl: HTMLInputElement | undefined = $state();

  const filtered = $derived(COMMANDS.filter((c) => c.label.toLowerCase().includes(query.toLowerCase())));

  $effect(() => {
    if (open) {
      query = "";
      index = 0;
      setTimeout(() => inputEl?.focus(), 10);
    }
  });

  $effect(() => {
    void query;
    index = 0;
  });

  function onKey(ev: KeyboardEvent) {
    if (!open) return;
    if (ev.key === "Escape") {
      onClose();
      return;
    }
    if (ev.key === "ArrowDown") {
      ev.preventDefault();
      index = Math.min(index + 1, filtered.length - 1);
    }
    if (ev.key === "ArrowUp") {
      ev.preventDefault();
      index = Math.max(index - 1, 0);
    }
    if (ev.key === "Enter") {
      ev.preventDefault();
      const c = filtered[index];
      if (c) {
        onAction(c.key);
        onClose();
      }
    }
  }
</script>

<svelte:document onkeydown={onKey} />

{#if open}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="backdrop" onclick={onClose}>
    <div class="panel" onclick={(ev) => ev.stopPropagation()}>
      <div class="search-row">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" class="search-icon">
          <circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.8" />
          <path d="M20 20l-4-4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" />
        </svg>
        <input bind:this={inputEl} bind:value={query} placeholder="Type a command or search…" />
        <span class="esc">ESC</span>
      </div>
      <div class="list">
        {#if filtered.length === 0}
          <div class="empty">No matching commands</div>
        {/if}
        {#each filtered as c, i (c.key)}
          <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
          <div
            class="cmd"
            class:hl={i === index}
            onmouseenter={() => (index = i)}
            onclick={() => {
              onAction(c.key);
              onClose();
            }}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" class="cmd-icon">
              <path d={c.d} stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
            <span class="cmd-label">{c.label}</span>
            {#each c.shortcut.split(" ") as k, ki (ki)}
              <span class="key">{k}</span>
            {/each}
          </div>
        {/each}
      </div>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(11, 13, 18, 0.5);
    z-index: 90;
    display: flex;
    justify-content: center;
    align-items: flex-start;
    padding-top: 14vh;
  }
  .panel {
    width: 560px;
    max-width: 90vw;
    background: var(--surface-inverse);
    border-radius: var(--radius-2xl);
    box-shadow: var(--shadow-lg);
    overflow: hidden;
  }
  .search-row {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-4) var(--space-5);
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  }
  .search-icon {
    color: rgba(255, 255, 255, 0.5);
    flex-shrink: 0;
  }
  input {
    flex: 1;
    border: none;
    outline: none;
    background: none;
    color: var(--text-inverse);
    font-family: var(--font-body);
    font-size: 15px;
  }
  .esc {
    font-family: var(--font-mono);
    font-size: 11px;
    color: rgba(255, 255, 255, 0.35);
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: var(--radius-sm);
    padding: var(--space-1) var(--space-2);
  }
  .list {
    max-height: 340px;
    overflow-y: auto;
    padding: var(--space-2);
  }
  .empty {
    padding: var(--space-5);
    text-align: center;
    color: rgba(255, 255, 255, 0.4);
    font-family: var(--font-body);
    font-size: 13.5px;
  }
  .cmd {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-3);
    border-radius: var(--radius-md);
    cursor: pointer;
    background: transparent;
  }
  .cmd.hl {
    background: rgba(255, 255, 255, 0.1);
  }
  .cmd-icon {
    color: rgba(255, 255, 255, 0.55);
    flex-shrink: 0;
  }
  .cmd-label {
    flex: 1;
    font-family: var(--font-body);
    font-size: 14.5px;
    color: var(--text-inverse);
  }
  .key {
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: rgba(255, 255, 255, 0.6);
    background: rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-sm);
    padding: 3px var(--space-2);
    min-width: 18px;
    text-align: center;
  }
</style>
