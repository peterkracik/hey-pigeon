<script lang="ts">
  import AccountSwitcher from "./AccountSwitcher.svelte";
  import Icon from "./ds/Icon.svelte";
  import type { Account, LabelDef } from "./data";

  let {
    open,
    active,
    onSelect,
    accounts,
    activeAccountId,
    unified,
    onSelectAccount,
    onToggleUnified,
    onAddAccount,
    counts,
    labels,
    width = 248,
    onResize,
    hidden = [],
    onHide,
    onUnhide,
    onSetColor,
    onRenameLabel,
    onDeleteLabel,
  }: {
    open: boolean;
    active: string;
    onSelect: (key: string) => void;
    accounts: Account[];
    activeAccountId: string;
    unified: boolean;
    onSelectAccount: (id: string) => void;
    onToggleUnified: (v: boolean) => void;
    onAddAccount?: () => void;
    counts: Record<string, number>;
    labels: LabelDef[];
    width?: number;
    onResize?: (w: number) => void;
    /** Hidden folder keys / `label:<id>` keys (localStorage pref). */
    hidden?: string[];
    onHide?: (key: string) => void;
    onUnhide?: (key: string) => void;
    onSetColor?: (key: string, tag: string) => void;
    onRenameLabel?: (key: string, newName: string) => void;
    onDeleteLabel?: (key: string) => void;
  } = $props();

  // ------------------------------------------------- right-click context menu

  const PALETTE = ["sky", "lavender", "mint", "amber", "coral"];

  let ctxMenu: {
    key: string;
    kind: "folder" | "label";
    name: string;
    tag?: string;
    x: number;
    y: number;
    hidden: boolean;
  } | null = $state(null);
  let ctxEl: HTMLDivElement | undefined = $state();
  let renaming = $state(false);
  let renameValue = $state("");
  let confirmDelete = $state(false);
  // Reveal mode: hidden items render dimmed, offering Unhide.
  let showingAll = $state(false);

  const hiddenSet = $derived(new Set(hidden));

  function openCtx(ev: MouseEvent, kind: "folder" | "label", key: string, name: string, tag?: string) {
    ev.preventDefault();
    renaming = false;
    confirmDelete = false;
    ctxMenu = {
      key,
      kind,
      name,
      tag,
      x: Math.max(8, Math.min(ev.clientX, window.innerWidth - 208)),
      y: Math.min(ev.clientY + 2, window.innerHeight - 200),
      hidden: hiddenSet.has(key),
    };
  }

  function hideItem(key: string) {
    onHide?.(key);
    ctxMenu = null;
  }

  function commitRename() {
    // Guard: Esc closes the menu first; the input's removal must not commit.
    if (!ctxMenu || !renaming) return;
    const v = renameValue.trim();
    if (v && v !== ctxMenu.name) onRenameLabel?.(ctxMenu.key, v);
    ctxMenu = null;
  }

  function autofocus(el: HTMLInputElement) {
    el.focus();
    el.select();
  }

  let resizing = $state(false);

  function startResize(ev: MouseEvent) {
    ev.preventDefault();
    resizing = true;
    const startX = ev.clientX;
    const startW = width;
    const move = (e: MouseEvent) => {
      onResize?.(Math.min(420, Math.max(200, startW + e.clientX - startX)));
    };
    const up = () => {
      resizing = false;
      document.removeEventListener("mousemove", move);
      document.removeEventListener("mouseup", up);
    };
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
  }

  const items = [
    { key: "all", label: "All emails", d: "M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1zM3 7l9 6 9-6" },
    { key: "inbox", label: "Inbox", d: "M3 7l9 6 9-6M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1z" },
    { key: "starred", label: "Starred", d: "M12 17v5M9 10.76a2 2 0 01-1.11 1.79l-1.78.9A2 2 0 005 15.24V16a1 1 0 001 1h12a1 1 0 001-1v-.76a2 2 0 00-1.11-1.79l-1.78-.9A2 2 0 0115 10.76V6h1a2 2 0 000-4H8a2 2 0 000 4h1z" },
    { key: "sent", label: "Sent", d: "M4 20l16-8L4 4l2 8-2 8z" },
    { key: "drafts", label: "Drafts", d: "M4 20l1-4L17 4l3 3L8 19l-4 1z" },
    // Checkbox, not a box: archive is "done" in this app's concept (the
    // list rows use the same todo-checkbox for done/archive).
    { key: "archive", label: "Archive", d: "M4 6a2 2 0 012-2h12a2 2 0 012 2v12a2 2 0 01-2 2H6a2 2 0 01-2-2V6z M8.5 12.5l2.5 2.5 5-5.5" },
    { key: "scheduled", label: "Scheduled", d: "M12 8v4l3 3M12 21a9 9 0 100-18 9 9 0 000 18z" },
    { key: "spam", label: "Spam", d: "M12 9v4m0 4h.01M10.3 3.9L2.9 17a1.8 1.8 0 001.5 2.7h15.2a1.8 1.8 0 001.5-2.7L13.7 3.9a1.8 1.8 0 00-3.4 0z" },
    { key: "trash", label: "Trash", d: "M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13" },
  ];

</script>

<svelte:document
  onmousedown={(ev) => {
    if (ctxMenu && ctxEl && !ctxEl.contains(ev.target as Node)) ctxMenu = null;
  }}
  onscrollcapture={() => {
    // The fixed-position menu detaches from its anchor when the nav scrolls.
    if (ctxMenu) ctxMenu = null;
  }}
/>
<svelte:window
  onkeydowncapture={(ev) => {
    // Close on Escape without letting the app-level Escape handling also
    // collapse the selection/thread (same pattern as the remind popover).
    if (ctxMenu && ev.key === "Escape") {
      ev.stopPropagation();
      renaming = false;
      ctxMenu = null;
    }
  }}
/>

<div class="sidebar" class:open class:resizing style:width={open ? `${width}px` : "0"}>
  <div class="inner" style:width="{width}px">
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="resize-handle" onmousedown={startResize}></div>
    <AccountSwitcher {accounts} activeId={activeAccountId} {unified} {onSelectAccount} {onToggleUnified} {onAddAccount} />
    <div class="nav">
      {#each items.filter((it) => showingAll || !hiddenSet.has(it.key)) as it (it.key)}
        <button
          class="nav-item"
          class:active={active === it.key}
          class:dimmed={hiddenSet.has(it.key)}
          onclick={() => onSelect(it.key)}
          oncontextmenu={(ev) => openCtx(ev, "folder", it.key, it.label)}
        >
          <Icon d={it.d} size={16} />
          <span class="nav-label" class:bold={active === it.key}>{it.label}</span>
          {#if counts[it.key] > 0}
            <span class="count">{counts[it.key]}</span>
          {/if}
        </button>
      {/each}
      <div class="divider"></div>
      <div class="section-title">Labels</div>
      {#each labels.filter((l) => showingAll || !hiddenSet.has(l.key)) as l (l.key)}
        <button
          class="nav-item label-item"
          class:active={active === l.key}
          class:dimmed={hiddenSet.has(l.key)}
          onclick={() => onSelect(l.key)}
          oncontextmenu={(ev) => openCtx(ev, "label", l.key, l.label, l.tag)}
        >
          <span class="label-dot" style:background="var(--tag-{l.tag}-fg)"></span>
          <span class="label-name">{l.label}</span>
        </button>
      {/each}
    </div>
    {#if hidden.length > 0}
      <button class="show-all" onclick={() => (showingAll = !showingAll)}>
        {showingAll ? "Showing all" : "Show all"}
      </button>
    {/if}
  </div>
</div>

{#if ctxMenu}
  {@const menu = ctxMenu}
  <div bind:this={ctxEl} class="ctx-menu" style:left="{menu.x}px" style:top="{menu.y}px">
    {#if menu.hidden}
      <button
        class="ctx-item"
        onclick={() => {
          onUnhide?.(menu.key);
          ctxMenu = null;
        }}
      >
        Unhide
      </button>
    {:else}
      <button class="ctx-item" onclick={() => hideItem(menu.key)}>Hide from sidebar</button>
    {/if}
    {#if menu.kind === "label"}
      {#if renaming}
        <!-- svelte-ignore a11y_autofocus -->
        <input
          class="ctx-rename"
          use:autofocus
          bind:value={renameValue}
          aria-label="Label name"
          onblur={commitRename}
          onkeydown={(ev) => {
            if (ev.key === "Enter") commitRename();
          }}
        />
      {:else}
        <button
          class="ctx-item"
          onclick={() => {
            renameValue = menu.name;
            renaming = true;
          }}
        >
          Rename…
        </button>
      {/if}
      <div class="ctx-colors">
        <span class="ctx-colors-label">Color</span>
        {#each PALETTE as tag (tag)}
          <button
            class="ctx-dot"
            class:sel={menu.tag === tag}
            style:background="var(--tag-{tag}-fg)"
            aria-label="Color {tag}"
            onclick={() => {
              onSetColor?.(menu.key, tag);
              ctxMenu = null;
            }}
          ></button>
        {/each}
      </div>
      <div class="ctx-divider"></div>
      <button
        class="ctx-item danger"
        onclick={() => {
          if (!confirmDelete) {
            confirmDelete = true;
            return;
          }
          onDeleteLabel?.(menu.key);
          ctxMenu = null;
        }}
      >
        {confirmDelete ? "Really delete?" : "Delete label…"}
      </button>
    {/if}
  </div>
{/if}

<style>
  .sidebar {
    width: 0;
    opacity: 0;
    overflow: hidden;
    flex-shrink: 0;
    border-right: none;
    background: var(--navy-50);
    transition:
      width var(--duration-base) var(--ease-standard),
      opacity var(--duration-base) var(--ease-standard);
  }
  .sidebar.open {
    opacity: 1;
    border-right: 1px solid var(--navy-50);
    /* let the account-switcher dropdown (and its shadow) escape the sidebar;
       hidden is only needed for the width-collapse animation when closing */
    overflow: visible;
  }
  .inner {
    position: relative;
    display: flex;
    flex-direction: column;
    height: 100%;
    /* Extra top room: the overlay titlebar's traffic lights float here. */
    padding: 46px 14px 18px;
    box-sizing: border-box;
  }

  .nav {
    display: flex;
    flex-direction: column;
    gap: 1px;
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    /* Bleed to the sidebar edges so item highlights run full width. */
    margin: 0 -14px;
  }
  .sidebar.resizing {
    transition: none;
  }
  .resize-handle {
    position: absolute;
    top: 0;
    right: -3px;
    width: 6px;
    height: 100%;
    cursor: col-resize;
    z-index: 10;
  }
  .resize-handle:hover {
    background: var(--border-default);
  }
  .nav-item {
    display: flex;
    align-items: center;
    gap: 10px;
    /* 22px = 14px inner padding + 8px — content stays put while the
       highlight spans the full bled .nav width. */
    padding: 8px 22px;
    border: none;
    cursor: pointer;
    text-align: left;
    background: none;
    border-radius: 0;
    color: var(--text-secondary);
  }
  /* Same treatment as list-row hover — inverted for the gray panel: white
     fill, honey left bar, square. */
  .nav-item:hover,
  .nav-item.active {
    background: var(--surface-card);
    box-shadow: inset 3px 0 0 var(--accent-highlight);
    color: var(--text-primary);
  }
  .nav-label {
    flex: 1;
    font-family: var(--font-body);
    font-size: 14px;
    font-weight: 400;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
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
    background: var(--border-default);
    margin: 10px 6px;
    flex-shrink: 0;
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
    padding: 7px 22px;
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
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }

  .nav-item.dimmed {
    opacity: 0.45;
  }
  .show-all {
    flex-shrink: 0;
    border: none;
    background: none;
    cursor: pointer;
    text-align: left;
    padding: 6px 8px 2px;
    font-family: var(--font-body);
    font-size: 12px;
    color: var(--text-tertiary);
  }
  .show-all:hover {
    color: var(--text-primary);
  }
  .ctx-menu {
    position: fixed;
    z-index: 90;
    width: 200px;
    background: var(--surface-card);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
    padding: 6px;
    box-sizing: border-box;
  }
  .ctx-item {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    border: none;
    background: none;
    cursor: pointer;
    padding: 8px;
    border-radius: var(--radius-md);
    text-align: left;
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-primary);
  }
  .ctx-item:hover {
    background: var(--surface-sunken);
  }
  .ctx-item.danger {
    color: var(--tag-coral-fg);
  }
  .ctx-divider {
    height: 1px;
    background: var(--navy-50);
    margin: 6px 4px;
  }
  .ctx-colors {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px;
  }
  .ctx-colors-label {
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-primary);
    margin-right: auto;
  }
  .ctx-dot {
    width: 12px;
    height: 12px;
    border-radius: 50%;
    border: none;
    padding: 0;
    cursor: pointer;
    flex-shrink: 0;
  }
  .ctx-dot.sel {
    outline: 2px solid var(--text-primary);
    outline-offset: 2px;
  }
  .ctx-rename {
    width: 100%;
    box-sizing: border-box;
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    padding: 7px 8px;
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-primary);
    background: var(--surface-sunken);
    outline: none;
  }
  .ctx-rename:focus {
    border-color: var(--accent-highlight);
  }
</style>
