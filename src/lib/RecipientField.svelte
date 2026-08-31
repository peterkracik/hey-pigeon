<script lang="ts">
  import { CONTACTS } from "./data";

  let { placeholder = "" }: { placeholder?: string } = $props();

  interface Chip {
    name: string;
    email: string;
  }

  let chips: Chip[] = $state([]);
  let value = $state("");
  let open = $state(false);
  let highlight = $state(0);
  let root: HTMLDivElement | undefined = $state();
  let inputEl: HTMLInputElement | undefined = $state();

  const matches = $derived(
    value
      ? CONTACTS.filter(
          (c) =>
            !chips.some((ch) => ch.email === c.email) &&
            (c.name.toLowerCase().includes(value.toLowerCase()) ||
              c.email.toLowerCase().includes(value.toLowerCase())),
        )
      : [],
  );

  function onDocMousedown(ev: MouseEvent) {
    if (root && !root.contains(ev.target as Node)) open = false;
  }

  function addChip(c: Chip) {
    chips = [...chips, c];
    value = "";
    open = false;
    highlight = 0;
    inputEl?.focus();
  }

  const isEmail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s.trim());

  function onKeyDown(ev: KeyboardEvent) {
    if (ev.key === "ArrowDown" && matches.length) {
      ev.preventDefault();
      highlight = (highlight + 1) % matches.length;
    } else if (ev.key === "ArrowUp" && matches.length) {
      ev.preventDefault();
      highlight = (highlight - 1 + matches.length) % matches.length;
    } else if ((ev.key === "Enter" || ev.key === ",") && value.trim()) {
      ev.preventDefault();
      addChip(matches[highlight] ?? { name: value.trim(), email: value.trim() });
    } else if (ev.key === " " && isEmail(value)) {
      ev.preventDefault();
      addChip({ name: value.trim(), email: value.trim() });
    } else if (ev.key === "Backspace" && !value && chips.length) {
      chips = chips.slice(0, -1);
    }
  }
</script>

<svelte:document onmousedown={onDocMousedown} />

{#snippet highlightMatch(text: string, query: string)}
  {@const i = query ? text.toLowerCase().indexOf(query.toLowerCase()) : -1}
  {#if i === -1}
    <span class="dim">{text}</span>
  {:else}
    <span>
      <span class="dim">{text.slice(0, i)}</span><span class="hit">{text.slice(i, i + query.length)}</span><span class="dim">{text.slice(i + query.length)}</span>
    </span>
  {/if}
{/snippet}

<div bind:this={root} class="root">
  <div class="field">
    {#each chips as c, i (c.email)}
      <span class="chip">
        {c.name}
        <button class="chip-x" aria-label="Remove {c.name}" onclick={() => (chips = chips.filter((_, j) => j !== i))}>
          <svg width="10" height="10" viewBox="0 0 24 24" fill="none">
            <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" />
          </svg>
        </button>
      </span>
    {/each}
    <input
      bind:this={inputEl}
      bind:value
      placeholder={chips.length ? "" : placeholder}
      oninput={() => {
        open = true;
        highlight = 0;
      }}
      onfocus={() => (open = true)}
      onkeydown={onKeyDown}
    />
  </div>
  {#if open && matches.length > 0}
    <div class="menu">
      {#each matches as c, i (c.email)}
        <button
          class="option"
          class:hl={i === highlight}
          onclick={() => addChip(c)}
          onmouseenter={() => (highlight = i)}
        >
          <span class="opt-name">{@render highlightMatch(c.name, value)}</span>
          <span class="opt-email">{@render highlightMatch(c.email, value)}</span>
        </button>
      {/each}
    </div>
  {/if}
</div>

<style>
  .root {
    position: relative;
    flex: 1;
    min-width: 0;
  }
  .field {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px;
    min-height: 22px;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 4px 3px 10px;
    background: var(--surface-sunken);
    border-radius: var(--radius-pill);
    font-family: var(--font-body);
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .chip-x {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    display: flex;
    padding: 3px;
  }
  input {
    border: none;
    outline: none;
    background: none;
    flex: 1;
    min-width: 60px;
    font-family: var(--font-body);
    font-size: 14px;
    color: var(--text-primary);
    padding: 2px 0;
  }
  .menu {
    position: absolute;
    top: 100%;
    left: 0;
    right: -400px;
    margin-top: 8px;
    background: var(--surface-card);
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-lg);
    z-index: 30;
    padding: 4px;
    min-width: 340px;
    max-height: 260px;
    overflow-y: auto;
    width: max-content;
  }
  .option {
    display: flex;
    align-items: baseline;
    gap: 16px;
    width: 100%;
    border: none;
    background: none;
    cursor: pointer;
    padding: 9px var(--space-3);
    border-radius: var(--radius-sm);
    text-align: left;
  }
  .option.hl {
    background: var(--surface-sunken);
  }
  .opt-name {
    font-family: var(--font-body);
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
    flex-shrink: 0;
    min-width: 130px;
  }
  .opt-email {
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-tertiary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .dim {
    color: var(--text-tertiary);
  }
  .hit {
    color: var(--text-primary);
    font-weight: 600;
  }
</style>
