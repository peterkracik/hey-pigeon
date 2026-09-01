<script lang="ts">
  import IconButton from "./ds/IconButton.svelte";
  import Tooltip from "./ds/Tooltip.svelte";
  import Icon from "./ds/Icon.svelte";
  import InlineReply from "./InlineReply.svelte";
  import HtmlEmailFrame from "./HtmlEmailFrame.svelte";
  import Avatar from "./ds/Avatar.svelte";
  import { EMAIL_ACTIONS, type Email } from "./data";

  let {
    emails,
    selectedId,
    onSelect,
    onOpen,
    onAction,
    onSendReply,
    onSchedule,
    hoverActions,
    pinListEnabled,
    signatureFor,
    mode = "inbox",
  }: {
    emails: Email[];
    selectedId: string | null;
    onSelect: (id: string | null) => void;
    onOpen: (id: string) => void;
    onAction: (id: string, action: string) => void;
    onSendReply?: (email: Email, body: string) => void;
    /** Set/clear the "remind me" schedule (epoch ms; null clears). */
    onSchedule?: (id: string, scheduledAt: number | null) => void;
    signatureFor?: (email: Email) => string | undefined;
    hoverActions: string[];
    pinListEnabled: boolean;
    /** 'scheduled' = calendar view: group by scheduledAt instead of date. */
    mode?: "inbox" | "scheduled";
  } = $props();

  const DONE_D = "M20 6L9 17l-5-5";

  let replyingId: string | null = $state(null);

  // ------------------------------------------------- remind/schedule popover

  interface RemindPreset {
    label: string;
    ts: number;
  }
  let remindMenu: {
    id: string;
    x: number;
    y: number;
    scheduled: boolean;
    presets: RemindPreset[];
  } | null = $state(null);
  let remindEl: HTMLDivElement | undefined = $state();

  // Custom pick step (native date/time inputs, no picker library).
  let pickOpen = $state(false);
  let pickDate = $state("");
  let pickTime = $state("");
  const pickTs = $derived.by(() => {
    if (!pickDate || !pickTime) return null;
    const ts = new Date(`${pickDate}T${pickTime}`).getTime();
    return Number.isNaN(ts) ? null : ts;
  });
  const pickInvalid = $derived(pickTs === null || pickTs <= Date.now());

  function confirmPick(id: string) {
    if (pickTs === null || pickTs <= Date.now()) return;
    onSchedule?.(id, pickTs);
    remindMenu = null;
  }

  const CLOCK_D = "M12 8v4l3 3M12 21a9 9 0 100-18 9 9 0 000 18z";
  const DAY_MS = 86_400_000;

  function remindPresets(): RemindPreset[] {
    const now = new Date();
    const at = (dayOffset: number, hour: number) => {
      const d = new Date(now);
      d.setDate(d.getDate() + dayOffset);
      d.setHours(hour, 0, 0, 0);
      return d.getTime();
    };
    // Later today: 18:00, or +3h once it's already past 17:00.
    const laterToday = now.getHours() >= 17 ? now.getTime() + 3 * 3_600_000 : at(0, 18);
    const daysToSat = (6 - now.getDay() + 7) % 7 || 7;
    const daysToMon = (1 - now.getDay() + 7) % 7 || 7;
    return [
      { label: "Later today", ts: laterToday },
      { label: "Tomorrow", ts: at(1, 9) },
      { label: "This weekend", ts: at(daysToSat, 9) },
      { label: "Next week", ts: at(daysToMon, 9) },
    ];
  }

  function openRemind(e: Email, btn: HTMLElement) {
    const r = btn.getBoundingClientRect();
    // Custom pick defaults: tomorrow 09:00.
    const pad = (n: number) => String(n).padStart(2, "0");
    const t = new Date();
    t.setDate(t.getDate() + 1);
    pickOpen = false;
    pickDate = `${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())}`;
    pickTime = "09:00";
    remindMenu = {
      id: e.id,
      x: Math.max(8, Math.min(r.right - 210, window.innerWidth - 218)),
      y: r.bottom + 6,
      scheduled: e.scheduledAt !== undefined,
      presets: remindPresets(),
    };
  }

  /** Short schedule stamp: "18:00" today, "Sat 9:00 AM" within a week, "Mar 2"
   * for anything further out — or overdue (a weekday-only stamp on a past
   * timestamp would read as upcoming). */
  function fmtSched(ts: number): string {
    const d = new Date(ts);
    const time = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    if (d.toDateString() === new Date().toDateString()) return time;
    const delta = ts - Date.now();
    if (delta > 0 && delta < 7 * DAY_MS)
      return `${d.toLocaleDateString([], { weekday: "short" })} ${time}`;
    return d.toLocaleDateString([], { month: "short", day: "numeric" });
  }

  // Rows currently playing the strike-through + fade-out before "done" fires.
  let completing = $state(new Set<string>());

  function clickDone(e: Email, ev: Event) {
    ev.stopPropagation();
    if (e.done) {
      onAction(e.id, "done"); // unchecking: no ceremony
      return;
    }
    if (completing.has(e.id)) return;
    completing = new Set(completing).add(e.id);
    setTimeout(() => {
      completing = new Set([...completing].filter((id) => id !== e.id));
      onAction(e.id, "done");
    }, 650);
  }

  $effect(() => {
    void selectedId;
    replyingId = null;
  });

  const pinned = $derived(pinListEnabled && mode === "inbox" ? emails.filter((e) => e.pinned) : []);
  const rest = $derived(pinned.length ? emails.filter((e) => !e.pinned) : emails);
  // Real date buckets when timestamps exist (live mode); the mock seed keeps
  // the design's fixed slices.
  const groups = $derived.by(() => {
    if (mode === "scheduled") {
      // Calendar/todo view: ascending by schedule; overdue sorts first in
      // Today naturally (earlier timestamps).
      const sorted = [...emails].sort((a, b) => (a.scheduledAt ?? 0) - (b.scheduledAt ?? 0));
      const startToday = new Date().setHours(0, 0, 0, 0);
      const t1 = startToday + DAY_MS;
      const t2 = startToday + 2 * DAY_MS;
      const t7 = startToday + 7 * DAY_MS;
      const at = (e: Email) => e.scheduledAt ?? 0;
      return [
        { label: "Today", items: sorted.filter((e) => at(e) < t1), isPinnedGroup: false },
        { label: "Tomorrow", items: sorted.filter((e) => at(e) >= t1 && at(e) < t2), isPinnedGroup: false },
        { label: "This week", items: sorted.filter((e) => at(e) >= t2 && at(e) < t7), isPinnedGroup: false },
        { label: "Later", items: sorted.filter((e) => at(e) >= t7), isPinnedGroup: false },
      ].filter((g) => g.items.length > 0);
    }
    const head = pinned.length ? [{ label: "Pinned", items: pinned, isPinnedGroup: true }] : [];
    if (!rest.some((e) => e.lastMsgAt !== undefined)) {
      // Pure mock data (browser demo) — keep the design's fixed slices.
      return [
        ...head,
        { label: "Today", items: rest.slice(0, 2), isPinnedGroup: false },
        { label: "Last 7 days", items: rest.slice(2), isPinnedGroup: false },
      ];
    }
    const startOfToday = new Date().setHours(0, 0, 0, 0);
    const weekAgo = startOfToday - 7 * 86_400_000;
    const at = (e: Email) => e.lastMsgAt ?? 0;
    const today = rest.filter((e) => at(e) >= startOfToday);
    const week = rest.filter((e) => at(e) < startOfToday && at(e) >= weekAgo);
    const older = rest.filter((e) => at(e) < weekAgo);
    return [
      ...head,
      { label: "Today", items: today, isPinnedGroup: false },
      { label: "Last 7 days", items: week, isPinnedGroup: false },
      { label: "Older", items: older, isPinnedGroup: false },
    ].filter((g) => g.items.length > 0);
  });
  const activeActions = $derived(
    (hoverActions.length ? hoverActions : ["done", "delete", "pin"])
      .map((k) => EMAIL_ACTIONS.find((a) => a.key === k))
      .filter((a): a is NonNullable<typeof a> => Boolean(a)),
  );

  // Preview renders the SAME content as the full thread view: the latest
  // message, as HTML when it is HTML, as text otherwise.
  function previewContent(e: Email): { html: boolean; body: string } {
    const last = e.thread?.[e.thread.length - 1];
    if (last) return { html: Boolean(last.html), body: last.body };
    return { html: Boolean(e.html), body: e.body || e.snippet };
  }

  function selectedDate(e: Email): string {
    return e.fullDate || (e.thread && e.thread[e.thread.length - 1].fullDate) || e.time;
  }
</script>

<svelte:document
  onmousedown={(ev) => {
    if (remindMenu && remindEl && !remindEl.contains(ev.target as Node)) remindMenu = null;
  }}
/>
<svelte:window
  onkeydowncapture={(ev) => {
    // Close the popover on Escape without letting the app-level Escape
    // handling also collapse the selection/thread.
    if (remindMenu && ev.key === "Escape") {
      ev.stopPropagation();
      remindMenu = null;
    }
  }}
/>

<div>
  {#each groups as g, gi (gi)}
    <div class:pinned-group={g.isPinnedGroup}>
      <div class="group-label">{g.label}</div>
      {#each g.items as e (e.id)}
        <div class:selected-card={selectedId === e.id}>
          <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
          <div
            class="row"
            class:is-selected={selectedId === e.id}
            class:completing={completing.has(e.id)}
            onclick={() => onSelect(selectedId === e.id ? null : e.id)}
          >
            <Tooltip label={e.done ? "Mark not done" : "Mark done"} side="bottom">
              <button
                class="star"
                class:done={e.done || completing.has(e.id)}
                title={e.done ? "Mark not done" : "Mark done"}
                onclick={(ev) => clickDone(e, ev)}
              >
                <Icon d={DONE_D} size={11} strokeWidth={2.6} />
              </button>
            </Tooltip>
            <span class="avatar-wrap">
              <Avatar email={e.fromAddr} accountId={e.accountId} name={e.from} size={26} />
              {#if e.accountTag}
                <span class="account-dot" title="account" style:background="var(--tag-{e.accountTag}-fg)"></span>
              {/if}
            </span>
            <span class="from" class:unread={e.unread}>{e.from}</span>
            <span class="subject-wrap">
              <span class="label-dot" style:background={e.labelTag ? `var(--tag-${e.labelTag}-fg)` : "transparent"}></span>
              <span class="subject" class:unread={e.unread}>{e.subject}</span>
            </span>
            <span class="snippet">{e.snippet}</span>
            {#if e.scheduledAt !== undefined}
              <span class="sched-badge" class:overdue={e.scheduledAt < Date.now()} title="Scheduled">
                <Icon d={CLOCK_D} size={11} />
                {fmtSched(e.scheduledAt)}
              </span>
            {/if}
            {#if e.attachment}
              <span class="clip" title="Has attachment">
                <Icon d="M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9" size={14} />
              </span>
            {/if}
            <span class="right" style:width={selectedId === e.id ? "190px" : "118px"}>
              <span class="time">{selectedId === e.id ? selectedDate(e) : e.time}</span>
              <div class="actions">
                {#each activeActions as def (def.key)}
                  {@const active = def.key === "pin" && e.pinned}
                  <button
                    class="action-btn"
                    class:pin-active={active}
                    title={def.label}
                    onclick={(ev) => {
                      ev.stopPropagation();
                      if (def.key === "remind" && onSchedule) {
                        openRemind(e, ev.currentTarget);
                        return;
                      }
                      onAction(e.id, def.key);
                    }}
                  >
                    <Icon d={def.d} size={15} fill={active ? "currentColor" : "none"} />
                  </button>
                {/each}
                <button
                  class="action-btn"
                  title="Open"
                  onclick={(ev) => {
                    ev.stopPropagation();
                    onOpen(e.id);
                  }}
                >
                  <Icon d="M9 6l6 6-6 6" size={15} />
                </button>
              </div>
            </span>
          </div>
          {#if selectedId === e.id}
            <div class="preview">
              {#if previewContent(e).html}
                <HtmlEmailFrame html={previewContent(e).body} />
              {:else}
                <p class="preview-body">{previewContent(e).body}</p>
              {/if}
              <div class="preview-actions">
                <div class="reply-btns">
                  <Tooltip label="Reply" side="top">
                    <IconButton
                      size="sm"
                      label="Reply"
                      onclick={(ev) => {
                        ev.stopPropagation();
                        replyingId = e.id;
                      }}
                    >
                      <Icon d="M9 17l-5-5 5-5M4 12h11a5 5 0 010 10h-1" size={15} />
                    </IconButton>
                  </Tooltip>
                  <Tooltip label="Reply all" side="top">
                    <IconButton
                      size="sm"
                      label="Reply all"
                      onclick={(ev) => {
                        ev.stopPropagation();
                        replyingId = e.id;
                      }}
                    >
                      <Icon d="M13 17l-5-5 5-5M6 17l-5-5 5-5M1 12h14a5 5 0 010 10h-1" size={15} />
                    </IconButton>
                  </Tooltip>
                  <Tooltip label="Forward" side="top">
                    <IconButton size="sm" label="Forward">
                      <Icon d="M15 17l5-5-5-5M20 12H9a5 5 0 000 10h1" size={15} />
                    </IconButton>
                  </Tooltip>
                </div>
                <div class="spacer"></div>
                <button
                  class="open-thread"
                  onclick={(ev) => {
                    ev.stopPropagation();
                    onOpen(e.id);
                  }}
                >
                  Open full thread
                  <Icon d="M9 6l6 6-6 6" size={15} />
                </button>
              </div>
              {#if replyingId === e.id}
                <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
                <div onclick={(ev) => ev.stopPropagation()}>
                  <InlineReply toName={e.from} signature={signatureFor?.(e)} onCancel={() => (replyingId = null)} onSend={(body) => onSendReply?.(e, body)} />
                </div>
              {/if}
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {/each}
</div>

{#if remindMenu}
  {@const menu = remindMenu}
  <div bind:this={remindEl} class="remind-menu" style:left="{menu.x}px" style:top="{menu.y}px">
    {#each menu.presets as p (p.label)}
      <button
        class="remind-item"
        onclick={() => {
          onSchedule?.(menu.id, p.ts);
          remindMenu = null;
        }}
      >
        <span class="remind-label">{p.label}</span>
        <span class="remind-when">{fmtSched(p.ts)}</span>
      </button>
    {/each}
    <div class="remind-divider"></div>
    {#if !pickOpen}
      <button class="remind-item" onclick={() => (pickOpen = true)}>
        <span class="remind-label">Pick date & time…</span>
      </button>
    {:else}
      <div class="remind-pick">
        <input class="pick-input" type="date" bind:value={pickDate} aria-label="Date" />
        <div class="pick-row">
          <input class="pick-input pick-time" type="time" bind:value={pickTime} aria-label="Time" />
          <button
            class="pick-confirm"
            disabled={pickInvalid}
            onclick={() => confirmPick(menu.id)}
          >
            Schedule
          </button>
        </div>
        {#if pickInvalid}
          <div class="pick-hint">Pick a time in the future</div>
        {/if}
      </div>
    {/if}
    {#if menu.scheduled}
      <div class="remind-divider"></div>
      <button
        class="remind-item remove"
        onclick={() => {
          onSchedule?.(menu.id, null);
          remindMenu = null;
        }}
      >
        <span class="remind-label">Remove schedule</span>
      </button>
    {/if}
  </div>
{/if}

<style>
  .pinned-group {
    padding-bottom: 24px;
    margin-bottom: 20px;
    border-bottom: 1px solid var(--border-subtle);
  }
  .group-label {
    padding: 18px 0 8px;
    font-family: var(--font-mono);
    font-size: 10px;
    color: var(--text-tertiary);
    font-weight: 400;
  }
  .selected-card {
    margin: 0 -16px 8px;
    background: var(--surface-card);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-lg);
    border: 1px solid var(--border-subtle);
    overflow: hidden;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 14px;
    box-sizing: border-box;
    text-align: left;
    padding: 11px 16px;
    margin: 0 -16px;
    border-radius: var(--radius-md);
    cursor: pointer;
    position: relative;
    background: transparent;
    border: 1px solid transparent;
    transition: background 120ms;
  }
  .selected-card .row {
    margin: 0;
    border-radius: 0;
  }
  /* Superhuman-style hover/focus: solid fill, no shadow, strong left bar. */
  .row:hover,
  .row:focus-visible {
    background: var(--navy-50);
    box-shadow: inset 3px 0 0 var(--accent-interactive);
    border-color: transparent;
  }
  .row.is-selected {
    background: transparent !important;
    border-color: transparent !important;
    box-shadow: none !important;
  }
  /* Todo-style checkbox: empty light-gray box, green when done. */
  .star {
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    border: 1.5px solid var(--border-default);
    border-radius: 4px;
    background: none;
    padding: 0;
    cursor: pointer;
    color: transparent;
    display: flex;
    align-items: center;
    justify-content: center;
    box-sizing: border-box;
    transition:
      background 100ms,
      border-color 100ms,
      color 100ms;
  }
  .star:hover {
    border-color: var(--text-tertiary);
    color: var(--text-tertiary);
  }
  .star.done {
    background: var(--tag-mint-fg);
    border-color: var(--tag-mint-fg);
    color: #fff;
  }
  /* Done animation: strike sweeps across the text, then the row fades out. */
  .row.completing {
    pointer-events: none;
    animation: row-out 240ms ease-in 400ms forwards;
  }
  /* One continuous line across the whole row. */
  .row.completing::after {
    content: "";
    position: absolute;
    left: 44px;
    right: 16px;
    top: 50%;
    height: 1.5px;
    border-radius: 1px;
    background: var(--text-tertiary);
    transform: scaleX(0);
    transform-origin: left center;
    animation: strike 300ms ease-out forwards;
  }
  .completing .from,
  .completing .subject,
  .completing .snippet {
    color: var(--text-tertiary);
    transition: color 300ms;
  }
  @keyframes strike {
    to {
      transform: scaleX(1);
    }
  }
  @keyframes row-out {
    to {
      opacity: 0;
      transform: translateX(14px);
    }
  }
  .avatar-wrap {
    position: relative;
    flex-shrink: 0;
  }
  .account-dot {
    position: absolute;
    bottom: -2px;
    right: -2px;
    width: 9px;
    height: 9px;
    border-radius: 50%;
    border: 1.5px solid var(--surface-card);
  }
  .from {
    width: 120px;
    flex-shrink: 0;
    font-family: var(--font-body);
    font-size: 12.5px;
    font-weight: 400;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .subject-wrap {
    display: flex;
    align-items: center;
    gap: 6px;
    flex: 0 1 auto;
    min-width: 60px;
    max-width: 270px;
  }
  .label-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .subject {
    font-family: var(--font-body);
    font-size: 12.5px;
    font-weight: 400;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .unread {
    font-weight: 600;
  }
  .snippet {
    flex: 1 1 100px;
    min-width: 0;
    font-family: var(--font-body);
    font-size: 12.5px;
    color: var(--text-tertiary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .clip {
    flex-shrink: 0;
    color: var(--text-tertiary);
    display: flex;
  }
  .sched-badge {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 2px 8px;
    border-radius: var(--radius-pill);
    background: var(--surface-sunken);
    color: var(--text-secondary);
    font-family: var(--font-mono);
    font-size: 10.5px;
    white-space: nowrap;
  }
  .sched-badge.overdue {
    color: var(--tag-coral-fg);
  }
  .remind-menu {
    position: fixed;
    z-index: 90;
    width: 210px;
    background: var(--surface-card);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
    padding: 6px;
    box-sizing: border-box;
  }
  .remind-item {
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
  }
  .remind-item:hover {
    background: var(--surface-sunken);
  }
  .remind-label {
    flex: 1;
    font-family: var(--font-body);
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
  }
  .remind-item.remove .remind-label {
    color: var(--text-tertiary);
  }
  .remind-when {
    font-family: var(--font-mono);
    font-size: 10.5px;
    color: var(--text-tertiary);
  }
  .remind-divider {
    height: 1px;
    background: var(--navy-50);
    margin: 6px 4px;
  }
  .remind-pick {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 4px 8px 6px;
  }
  .pick-row {
    display: flex;
    gap: 6px;
  }
  .pick-input {
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    background: none;
    color: var(--text-primary);
    font-family: var(--font-body);
    font-size: 12.5px;
    padding: 4px 7px;
    box-sizing: border-box;
    width: 100%;
    min-width: 0;
  }
  /* Not `.time` — that class is the absolutely-positioned row timestamp
     below, and matching it here tears the input out of .pick-row and
     stretches it over the whole popover. */
  .pick-input.pick-time {
    flex: 1;
  }
  .pick-confirm {
    border: none;
    background: var(--text-primary);
    color: var(--surface-card);
    font-family: var(--font-body);
    font-size: 12px;
    font-weight: 600;
    border-radius: var(--radius-md);
    padding: 4px 10px;
    cursor: pointer;
    flex-shrink: 0;
  }
  .pick-confirm:disabled {
    opacity: 0.4;
    cursor: default;
  }
  .pick-hint {
    font-family: var(--font-body);
    font-size: 11px;
    color: var(--tag-coral-fg);
  }
  .right {
    position: relative;
    flex-shrink: 0;
    height: 17px;
  }
  .time {
    position: absolute;
    inset: 0;
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--text-tertiary);
    text-align: right;
    overflow: hidden;
    white-space: nowrap;
    transition: opacity 100ms;
  }
  .actions {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 2px;
    opacity: 0;
    transition: opacity 100ms;
  }
  .row:hover .time {
    opacity: 0;
  }
  .row:hover .actions {
    opacity: 1;
  }
  .action-btn {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    display: flex;
    padding: 4px;
  }
  .action-btn:hover {
    color: var(--text-primary);
  }
  .action-btn.pin-active,
  .action-btn.pin-active:hover {
    color: var(--blue-600, var(--tag-sky-fg));
  }
  .preview {
    padding: 20px 16px 12px;
  }
  .preview-body {
    margin: 0;
    font-family: var(--font-body);
    font-size: 13px;
    line-height: 1.6;
    color: var(--text-secondary);
    white-space: pre-wrap;
  }
  .preview-actions {
    display: flex;
    align-items: center;
    margin-top: 20px;
  }
  .reply-btns {
    display: flex;
    gap: 2px;
    margin-left: -6px;
  }
  .spacer {
    flex: 1;
  }
  .open-thread {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--accent-highlight);
    font-family: var(--font-body);
    font-size: 12.5px;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 0;
  }
</style>
