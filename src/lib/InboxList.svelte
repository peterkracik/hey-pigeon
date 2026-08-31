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
    hoverActions,
    pinListEnabled,
    signatureFor,
  }: {
    emails: Email[];
    selectedId: string | null;
    onSelect: (id: string | null) => void;
    onOpen: (id: string) => void;
    onAction: (id: string, action: string) => void;
    onSendReply?: (email: Email, body: string) => void;
    signatureFor?: (email: Email) => string | undefined;
    hoverActions: string[];
    pinListEnabled: boolean;
  } = $props();

  const DONE_D = "M20 6L9 17l-5-5";

  let replyingId: string | null = $state(null);

  $effect(() => {
    void selectedId;
    replyingId = null;
  });

  const pinned = $derived(pinListEnabled ? emails.filter((e) => e.pinned) : []);
  const rest = $derived(pinListEnabled ? emails.filter((e) => !e.pinned) : emails);
  // Real date buckets when timestamps exist (live mode); the mock seed keeps
  // the design's fixed slices.
  const groups = $derived.by(() => {
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

<div>
  {#each groups as g, gi (gi)}
    <div class:pinned-group={g.isPinnedGroup}>
      <div class="group-label">{g.label}</div>
      {#each g.items as e (e.id)}
        <div class:selected-card={selectedId === e.id}>
          <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
          <div class="row" class:is-selected={selectedId === e.id} onclick={() => onSelect(selectedId === e.id ? null : e.id)}>
            <Tooltip label={e.done ? "Mark not done" : "Mark done"} side="bottom">
              <button
                class="star"
                class:done={e.done}
                title={e.done ? "Mark not done" : "Mark done"}
                onclick={(ev) => {
                  ev.stopPropagation();
                  onAction(e.id, "done");
                }}
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
    font-weight: 600;
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
  .row:hover {
    background: var(--surface-card);
    box-shadow: var(--shadow-sm);
    border-color: var(--border-subtle);
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
