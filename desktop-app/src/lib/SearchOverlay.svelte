<script lang="ts">
  import Avatar from "./ds/Avatar.svelte";
  import * as ipc from "./ipc";
  import type { Account } from "./data";

  let {
    open,
    onClose,
    onOpen,
    accounts = [],
  }: {
    open: boolean;
    onClose: () => void;
    /** Open a search hit (Tauri mode only). */
    onOpen?: (thread: ipc.BackendThread) => void;
    accounts?: Account[];
  } = $props();

  // Browser mock keeps a static contact list; the real search needs Tauri.
  const contacts = [
    { n: "Priya Nair", e: "priya@heypigeon.app" },
    { n: "Sam Okoye", e: "sam@heypigeon.app" },
    { n: "Ana Torres", e: "ana@heypigeon.app" },
  ];

  let query = $state("");
  let results: ipc.BackendSearchResult[] = $state([]);
  let sel = $state(0);
  let inputEl: HTMLInputElement | undefined = $state();

  // Filter chips write operators INTO the query string — it stays the single
  // source of truth, so typed operators light the same chips up.
  const unreadOn = $derived(/(^|\s)is:unread(\s|$)/i.test(query));
  const activeAccount = $derived(query.match(/(^|\s)account:(\S+)/i)?.[2] ?? null);

  function focusInput() {
    requestAnimationFrame(() => inputEl?.focus());
  }
  function toggleUnread() {
    query = unreadOn
      ? query.replace(/(^|\s)is:unread(?=\s|$)/gi, " ").replace(/\s{2,}/g, " ").trim()
      : query ? `${query.trim()} is:unread` : "is:unread";
    focusInput();
  }
  function toggleAccount(email: string) {
    const had = activeAccount === email;
    query = query.replace(/(^|\s)account:\S+/gi, " ").replace(/\s{2,}/g, " ").trim();
    if (!had) query = query ? `${query} account:${email}` : `account:${email}`;
    focusInput();
  }
  /** Append `from:` / `to:` and put the caret right after it. */
  function insertOp(op: string) {
    if (!new RegExp(`(^|\\s)${op}\\S*`, "i").test(query)) {
      query = query ? `${query.replace(/\s+$/, "")} ${op}` : op;
    }
    focusInput();
  }
  // Monotonic token: a slow earlier query must not clobber a newer one.
  let seq = 0;

  $effect(() => {
    if (open) {
      query = "";
      results = [];
      sel = 0;
    }
  });

  $effect(() => {
    if (!open || !ipc.isTauri) return;
    const q = query;
    const my = ++seq;
    if (!q.trim()) {
      results = [];
      sel = 0;
      return;
    }
    ipc
      .searchThreads(q, 40)
      .then((r) => {
        if (my !== seq) return;
        results = r;
        sel = 0;
      })
      .catch((e) => console.error("search failed", e));
  });

  // Project hits through the same mapper the list uses — same names/times.
  const rows = $derived(results.map((r) => ({ email: ipc.threadToEmail(r.thread), raw: r })));

  /** Split an FTS5 snippet on the private-use highlight markers. */
  function segments(s: string): { t: string; hl: boolean }[] {
    const out: { t: string; hl: boolean }[] = [];
    let hl = false;
    for (const piece of s.split(/([\ue000\ue001])/)) {
      if (piece === ipc.SNIPPET_START) hl = true;
      else if (piece === ipc.SNIPPET_END) hl = false;
      else if (piece) out.push({ t: piece, hl });
    }
    return out;
  }

  function openResult(i: number) {
    const hit = results[i];
    if (hit && onOpen) onOpen(hit.thread);
  }

  function onKeydown(ev: KeyboardEvent) {
    if (ev.key === "Escape") {
      ev.preventDefault();
      onClose();
    } else if (ev.key === "ArrowDown") {
      ev.preventDefault();
      if (results.length) sel = Math.min(sel + 1, results.length - 1);
    } else if (ev.key === "ArrowUp") {
      ev.preventDefault();
      if (results.length) sel = Math.max(sel - 1, 0);
    } else if (ev.key === "Enter") {
      ev.preventDefault();
      openResult(sel);
    }
  }
</script>

{#if open}
  <div class="search-top">
  <div class="search-title-row">
    <span class="view-title">Search</span>
  </div>
  <div class="search-head">
    <svg class="lens" width="18" height="18" viewBox="0 0 24 24" fill="none">
      <circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.6" />
      <path d="M20 20l-4-4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
    </svg>
    <!-- svelte-ignore a11y_autofocus -->
    <input
      autofocus
      bind:this={inputEl}
      placeholder="Search mail — try from:, to:, is:unread"
      autocomplete="off"
      autocorrect="off"
      autocapitalize="off"
      spellcheck="false"
      bind:value={query}
      onkeydown={onKeydown}
    />
    <span class="hint">esc</span>
    <button class="close" aria-label="Close search" onclick={onClose}>
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
        <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
      </svg>
    </button>
  </div>
  <div class="filters">
    <button class="filter-chip" class:on={unreadOn} onclick={toggleUnread}>
      <span class="chip-dot"></span>
      Unread
    </button>
    {#if accounts.length > 1}
      {#each accounts as a (a.id)}
        <button
          class="filter-chip"
          class:on={activeAccount === a.email}
          onclick={() => toggleAccount(a.email)}
        >
          <span class="chip-dot acct" style:background="var(--tag-{a.tag}-fg)"></span>
          {a.label}
        </button>
      {/each}
    {/if}
    <span class="filter-sep"></span>
    <button class="filter-op" onclick={() => insertOp("from:")}>from:</button>
    <button class="filter-op" onclick={() => insertOp("to:")}>to:</button>
  </div>
  </div>

  {#if ipc.isTauri}
    {#if rows.length}
      <div class="group-label">Results</div>
    {/if}
    {#each rows as { email: e, raw: r }, i (e.id)}
      <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
      <div
        class="row"
        class:selected={i === sel}
        onmouseenter={() => (sel = i)}
        onclick={() => openResult(i)}
      >
        <span
          class="avatar-wrap"
          class:ringed={!!e.accountTag}
          style:--ring={e.accountTag ? `var(--tag-${e.accountTag}-fg)` : undefined}
        >
          <Avatar email={e.fromAddr} accountId={e.accountId} name={e.from} size={26} />
        </span>
        <span class="from">{e.from}</span>
        <span class="subject">{e.subject}</span>
        <span class="snippet">
          {#each segments(r.snippet) as seg, j (j)}
            {#if seg.hl}<mark>{seg.t}</mark>{:else}{seg.t}{/if}
          {/each}
        </span>
        <span class="time">{e.time}</span>
      </div>
    {:else}
      {#if query.trim()}
        <div class="none">No results for “{query}”</div>
      {/if}
    {/each}
  {:else}
    {#each contacts as c (c.e)}
      <div class="row">
        <span class="from">{c.n}</span>
        <span class="snippet">{c.e}</span>
      </div>
    {/each}
  {/if}
{/if}

<style>
  /* Title + input stay pinned while results scroll. */
  .search-top {
    position: sticky;
    top: 0;
    z-index: 10;
    background: var(--surface-card);
  }
  /* Same title treatment as the folder views ("All inboxes"). */
  .search-title-row {
    display: flex;
    align-items: center;
    /* min-height matches the topbar's md IconButton row (36px) so the title
       sits at exactly the same height as on the folder views. */
    min-height: 36px;
    padding: 12px 0 16px;
  }
  .view-title {
    font-family: var(--font-display);
    font-weight: 700;
    font-size: 20px;
    color: var(--text-primary);
  }
  .search-head {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 0 0 14px;
  }
  .filters {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 0 14px;
    border-bottom: 1px solid var(--border-subtle);
    margin-bottom: 8px;
    flex-wrap: wrap;
  }
  .filter-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    border: 1px solid var(--border-default);
    background: var(--surface-card);
    cursor: pointer;
    padding: 5px 12px;
    border-radius: var(--radius-pill);
    font-family: var(--font-body);
    font-size: 12.5px;
    font-weight: 600;
    color: var(--text-secondary);
    transition:
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard);
  }
  .filter-chip:hover {
    background: var(--surface-hover);
    color: var(--text-primary);
  }
  .filter-chip.on {
    background: var(--surface-inverse);
    border-color: var(--surface-inverse);
    color: var(--text-inverse);
  }
  .chip-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--accent-highlight);
    flex-shrink: 0;
  }
  .filter-sep {
    width: 1px;
    height: 18px;
    background: var(--border-default);
    margin: 0 2px;
  }
  .filter-op {
    border: none;
    background: none;
    cursor: pointer;
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--text-tertiary);
    padding: 5px 6px;
    border-radius: var(--radius-sm);
  }
  .filter-op:hover {
    color: var(--text-primary);
    background: var(--surface-hover);
  }
  .lens {
    color: var(--text-tertiary);
    flex-shrink: 0;
  }
  input {
    flex: 1;
    border: none;
    outline: none;
    background: none;
    font-family: var(--font-body);
    font-size: 14px;
    color: var(--text-primary);
  }
  input::placeholder {
    color: var(--text-tertiary);
  }
  .hint {
    font-family: var(--font-mono);
    font-size: 10px;
    color: var(--text-tertiary);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-sm);
    padding: 2px 5px;
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
  .group-label {
    padding: 18px 0 8px;
    font-family: var(--font-body);
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--text-tertiary);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 11px 16px;
    margin: 0 -16px;
    cursor: pointer;
    font-family: var(--font-body);
  }
  .row.selected {
    background: var(--surface-hover);
    border-radius: var(--radius-md);
  }
  .avatar-wrap {
    position: relative;
    flex-shrink: 0;
    display: flex;
    border-radius: 50%;
  }
  .avatar-wrap.ringed {
    box-shadow:
      0 0 0 1.5px var(--surface-card),
      0 0 0 3px var(--ring);
  }
  .from {
    width: 200px;
    margin-right: 12px;
    flex-shrink: 0;
    font-size: 12.5px;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .subject {
    flex: 0 1 auto;
    min-width: 60px;
    max-width: 340px;
    font-size: 13px;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .snippet {
    flex: 1;
    min-width: 0;
    font-size: 13px;
    color: var(--text-tertiary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .snippet mark {
    background: var(--accent-highlight-bg);
    color: var(--text-primary);
    font-weight: 600;
    border-radius: 2px;
    padding: 0 1px;
  }
  .time {
    flex-shrink: 0;
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-tertiary);
  }
  .none {
    color: var(--text-tertiary);
    font-family: var(--font-body);
    font-size: 14px;
    padding: 24px 0;
  }
</style>
