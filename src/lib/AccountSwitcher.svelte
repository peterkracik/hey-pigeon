<script lang="ts">
  import { initials, type Account } from "./data";

  let {
    accounts,
    activeId,
    unified,
    onSelectAccount,
    onToggleUnified,
  }: {
    accounts: Account[];
    activeId: string;
    unified: boolean;
    onSelectAccount: (id: string) => void;
    onToggleUnified: (v: boolean) => void;
  } = $props();

  let open = $state(false);
  let root: HTMLDivElement | undefined = $state();

  const active = $derived(accounts.find((a) => a.id === activeId) ?? accounts[0]);

  function onDocMousedown(ev: MouseEvent) {
    if (open && root && !root.contains(ev.target as Node)) open = false;
  }
</script>

<svelte:document onmousedown={onDocMousedown} />

{#snippet unifiedIcon()}
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
    <rect x="3" y="3" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.8" />
    <rect x="13" y="3" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.8" />
    <rect x="3" y="13" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.8" />
    <rect x="13" y="13" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.8" />
  </svg>
{/snippet}

{#snippet avatar(a: Account, size: number = 28)}
  <span
    class="avatar"
    style:width="{size}px"
    style:height="{size}px"
    style:background="var(--tag-{a.tag}-bg)"
    style:color="var(--tag-{a.tag}-fg)"
    style:font-size="{size * 0.4}px">{initials(a.label)}</span
  >
{/snippet}

<div bind:this={root} class="root">
  <button class="trigger" onclick={() => (open = !open)}>
    {#if unified}
      <span class="unified-badge">{@render unifiedIcon()}</span>
    {:else}
      {@render avatar(active)}
    {/if}
    <span class="trigger-label">{unified ? "All inboxes" : active.email}</span>
    <svg class="chevron" class:open width="13" height="13" viewBox="0 0 24 24" fill="none">
      <path d="M9 6l6 6-6 6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  </button>
  {#if open}
    <div class="menu">
      <button
        class="item"
        class:selected={unified}
        onclick={() => {
          onToggleUnified(true);
          open = false;
        }}
      >
        <span class="unified-badge">{@render unifiedIcon()}</span>
        <span class="item-title">All inboxes</span>
      </button>
      <div class="divider"></div>
      {#each accounts as a (a.id)}
        <button
          class="item"
          class:selected={!unified && a.id === activeId}
          onclick={() => {
            onSelectAccount(a.id);
            onToggleUnified(false);
            open = false;
          }}
        >
          {@render avatar(a)}
          <span class="item-body">
            <div class="item-title">{a.label}</div>
            <div class="item-sub">{a.email}</div>
          </span>
        </button>
      {/each}
      <div class="divider"></div>
      <button class="item add">
        <span class="add-badge">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
            <path d="M12 5v14M5 12h14" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" />
          </svg>
        </span>
        <span class="add-label">Add account</span>
      </button>
    </div>
  {/if}
</div>

<style>
  .root {
    position: relative;
    margin-bottom: 14px;
  }
  .avatar {
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: var(--font-body);
    font-weight: 700;
    flex-shrink: 0;
  }
  .unified-badge {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: var(--accent-soft);
    color: var(--text-primary);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .trigger {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    border: none;
    background: none;
    cursor: pointer;
    padding: 6px 4px;
    border-radius: var(--radius-md);
  }
  .trigger:hover {
    background: var(--surface-sunken);
  }
  .trigger-label {
    flex: 1;
    text-align: left;
    font-family: var(--font-body);
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .chevron {
    transition: transform 160ms;
    flex-shrink: 0;
    color: var(--text-tertiary);
  }
  .chevron.open {
    transform: rotate(90deg);
  }
  .menu {
    position: absolute;
    top: 100%;
    left: 0;
    right: -8px;
    margin-top: 6px;
    background: var(--surface-card);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
    z-index: 50;
    padding: 6px;
    min-width: 240px;
  }
  .item {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    border: none;
    background: none;
    cursor: pointer;
    padding: 8px 8px;
    border-radius: var(--radius-md);
    text-align: left;
  }
  .item.selected {
    background: var(--surface-sunken);
  }
  .item-body {
    flex: 1;
    min-width: 0;
  }
  .item-title {
    font-family: var(--font-body);
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .item-sub {
    font-family: var(--font-body);
    font-size: 12.5px;
    color: var(--text-tertiary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .divider {
    height: 1px;
    background: var(--navy-50);
    margin: 6px 4px;
  }
  .add {
    color: var(--text-secondary);
  }
  .add-badge {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    border: 1px dashed var(--border-default);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-tertiary);
    box-sizing: border-box;
  }
  .add-label {
    font-family: var(--font-body);
    font-size: 14px;
  }
</style>
