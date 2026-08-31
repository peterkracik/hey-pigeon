<script lang="ts">
  import * as ipc from "./ipc";

  let {
    open,
    onClose,
    onOpen,
  }: {
    open: boolean;
    onClose: () => void;
    /** Open a search hit (Tauri mode only). */
    onOpen?: (thread: ipc.BackendThread) => void;
  } = $props();

  // Browser mock keeps the static contact list; the real search needs Tauri.
  const contacts = [
    { n: "Priya Nair", e: "priya@heypigeon.app" },
    { n: "Sam Okoye", e: "sam@heypigeon.app" },
    { n: "Ana Torres", e: "ana@heypigeon.app" },
  ];

  let query = $state("");
  let results: ipc.BackendSearchResult[] = $state([]);
  let sel = $state(0);
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
  <div class="overlay">
    <div class="search-row">
      <!-- svelte-ignore a11y_autofocus -->
      <input
        autofocus
        placeholder="Search"
        bind:value={query}
        onkeydown={onKeydown}
      />
      <button class="close" aria-label="Close search" onclick={onClose}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
          <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
        </svg>
      </button>
    </div>
    {#if ipc.isTauri}
      {#each results as r, i (r.thread.id)}
        <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
        <div
          class="result"
          class:selected={i === sel}
          onmouseenter={() => (sel = i)}
          onclick={() => openResult(i)}
        >
          <div class="result-top">
            <span class="name">{r.thread.from_summary}</span>
            <span class="subject">{r.thread.subject}</span>
          </div>
          <div class="snippet">
            {#each segments(r.snippet) as seg, j (j)}
              {#if seg.hl}<mark>{seg.t}</mark>{:else}{seg.t}{/if}
            {/each}
          </div>
        </div>
      {:else}
        {#if query.trim()}
          <div class="none">No results</div>
        {/if}
      {/each}
    {:else}
      {#each contacts as c (c.e)}
        <div class="contact">
          <span class="name">{c.n}</span>
          <span class="email">{c.e}</span>
        </div>
      {/each}
    {/if}
  </div>
{/if}

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: var(--surface-card);
    z-index: 60;
    padding: 24px 32px;
    overflow-y: auto;
  }
  .search-row {
    display: flex;
    align-items: center;
    gap: 12px;
    border-bottom: 1px solid var(--border-subtle);
    padding-bottom: 14px;
    margin-bottom: 20px;
  }
  input {
    flex: 1;
    border: none;
    outline: none;
    background: none;
    font-family: var(--font-body);
    font-size: 20px;
    color: var(--text-primary);
  }
  .close {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
  }
  .result {
    padding: 10px 12px;
    margin: 0 -12px;
    border-radius: var(--radius-md, 8px);
    cursor: pointer;
    font-family: var(--font-body);
  }
  .result.selected {
    background: var(--surface-hover, rgba(0, 0, 0, 0.05));
  }
  .result-top {
    display: flex;
    gap: 12px;
    align-items: baseline;
  }
  .subject {
    color: var(--text-secondary, var(--text-primary));
    font-size: 14px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .snippet {
    color: var(--text-tertiary);
    font-size: 13px;
    margin-top: 2px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .snippet mark {
    background: none;
    color: var(--text-primary);
    font-weight: 600;
  }
  .none {
    color: var(--text-tertiary);
    font-family: var(--font-body);
    font-size: 14px;
    padding: 12px 0;
  }
  .contact {
    display: flex;
    gap: 16px;
    padding: 9px 0;
    font-family: var(--font-body);
    font-size: 14px;
  }
  .name {
    color: var(--text-primary);
    font-weight: 500;
  }
  .email {
    color: var(--text-tertiary);
  }
</style>
