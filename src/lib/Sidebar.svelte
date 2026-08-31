<script lang="ts">
  import AccountSwitcher from "./AccountSwitcher.svelte";
  import Icon from "./ds/Icon.svelte";
  import type { Account, LabelDef } from "./data";

  let {
    open,
    onClose,
    active,
    onSelect,
    accounts,
    activeAccountId,
    unified,
    onSelectAccount,
    onToggleUnified,
    counts,
    labels,
  }: {
    open: boolean;
    onClose: () => void;
    active: string;
    onSelect: (key: string) => void;
    accounts: Account[];
    activeAccountId: string;
    unified: boolean;
    onSelectAccount: (id: string) => void;
    onToggleUnified: (v: boolean) => void;
    counts: Record<string, number>;
    labels: LabelDef[];
  } = $props();

  const items = [
    { key: "all", label: "All emails", d: "M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1zM3 7l9 6 9-6" },
    { key: "inbox", label: "Inbox", d: "M3 7l9 6 9-6M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1z" },
    { key: "starred", label: "Starred", d: "M12 3l2.6 5.6 6.1.6-4.6 4.1 1.3 6-5.4-3.1-5.4 3.1 1.3-6-4.6-4.1 6.1-.6z" },
    { key: "sent", label: "Sent", d: "M4 20l16-8L4 4l2 8-2 8z" },
    { key: "drafts", label: "Drafts", d: "M4 20l1-4L17 4l3 3L8 19l-4 1z" },
    { key: "archive", label: "Archive", d: "M3 7h18M5 7v12a1 1 0 001 1h12a1 1 0 001-1V7M9 11h6" },
    { key: "scheduled", label: "Scheduled", d: "M12 8v4l3 3M12 21a9 9 0 100-18 9 9 0 000 18z" },
    { key: "spam", label: "Spam", d: "M12 9v4m0 4h.01M10.3 3.9L2.9 17a1.8 1.8 0 001.5 2.7h15.2a1.8 1.8 0 001.5-2.7L13.7 3.9a1.8 1.8 0 00-3.4 0z" },
    { key: "trash", label: "Trash", d: "M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13" },
  ];

  const SETTINGS_D =
    "M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 11-4 0v-.09a1.65 1.65 0 00-1-1.51 1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 11-2.83-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 110-4h.09a1.65 1.65 0 001.51-1 1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 112.83-2.83l.06.06a1.65 1.65 0 001.82.33h0A1.65 1.65 0 0010 3.09V3a2 2 0 114 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 112.83 2.83l-.06.06a1.65 1.65 0 00-.33 1.82v0c.27.6.85 1 1.51 1H21a2 2 0 110 4h-.09a1.65 1.65 0 00-1.51 1z";
</script>

<div class="sidebar" class:open>
  <div class="inner">
    <div class="header">
      <span class="brand">Hey Pigeon</span>
      <button class="close" title="Close sidebar" onclick={onClose}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
          <path
            d="M9 4H5a1 1 0 00-1 1v14a1 1 0 001 1h4M15 4h4a1 1 0 011 1v14a1 1 0 01-1 1h-4M9 4v16"
            stroke="currentColor"
            stroke-width="1.6"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </button>
    </div>
    <AccountSwitcher {accounts} activeId={activeAccountId} {unified} {onSelectAccount} {onToggleUnified} />
    <div class="nav">
      {#each items as it (it.key)}
        <button class="nav-item" class:active={active === it.key} onclick={() => onSelect(it.key)}>
          <Icon d={it.d} size={16} />
          <span class="nav-label" class:bold={active === it.key}>{it.label}</span>
          {#if counts[it.key] > 0}
            <span class="count">{counts[it.key]}</span>
          {/if}
        </button>
      {/each}
      <div class="divider"></div>
      <div class="section-title">Labels</div>
      {#each labels as l (l.key)}
        <button class="nav-item label-item" class:active={active === l.key} onclick={() => onSelect(l.key)}>
          <span class="label-dot" style:background="var(--tag-{l.tag}-fg)"></span>
          <span class="label-name">{l.label}</span>
        </button>
      {/each}
    </div>
    <div class="divider footer-divider"></div>
    <button class="nav-item settings" class:active={active === "settings"} onclick={() => onSelect("settings")}>
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
        <path d="M12 15a3 3 0 100-6 3 3 0 000 6z" stroke="currentColor" stroke-width="1.6" />
        <path d={SETTINGS_D} stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
      <span class="nav-label" class:bold={active === "settings"}>Settings</span>
    </button>
  </div>
</div>

<style>
  .sidebar {
    width: 0;
    opacity: 0;
    overflow: hidden;
    flex-shrink: 0;
    border-right: none;
    background: var(--surface-card);
    transition:
      width var(--duration-base) var(--ease-standard),
      opacity var(--duration-base) var(--ease-standard);
  }
  .sidebar.open {
    width: 248px;
    opacity: 1;
    border-right: 1px solid var(--navy-50);
  }
  .inner {
    width: 248px;
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 18px 14px;
    box-sizing: border-box;
  }
  .header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 4px 16px;
  }
  .brand {
    flex: 1;
    font-family: var(--font-display);
    font-weight: 800;
    font-size: 16px;
    color: var(--text-primary);
  }
  .close {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    display: flex;
    padding: 4px;
  }
  .close:hover {
    color: var(--text-primary);
  }
  .nav {
    display: flex;
    flex-direction: column;
    gap: 1px;
    flex: 1;
    overflow-y: auto;
  }
  .nav-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 8px;
    border: none;
    cursor: pointer;
    text-align: left;
    background: none;
    border-radius: var(--radius-md);
    color: var(--text-secondary);
  }
  .nav-item.active {
    background: var(--surface-sunken);
    color: var(--text-primary);
  }
  .nav-label {
    flex: 1;
    font-family: var(--font-body);
    font-size: 14px;
    font-weight: 400;
  }
  .nav-label.bold {
    font-weight: 600;
  }
  .count {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--text-tertiary);
  }
  .divider {
    height: 1px;
    background: var(--navy-50);
    margin: 10px 6px;
    flex-shrink: 0;
  }
  .footer-divider {
    margin: 6px 6px;
  }
  .section-title {
    font-family: var(--font-body);
    font-size: 12px;
    font-weight: 600;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.3px;
    padding: 4px 8px 6px;
  }
  .label-item {
    padding: 7px 8px;
  }
  .label-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .label-name {
    font-family: var(--font-body);
    font-size: 13.5px;
  }
  .settings {
    flex-shrink: 0;
  }
</style>
