<script lang="ts">
  import IconButton from "./ds/IconButton.svelte";
  import Tooltip from "./ds/Tooltip.svelte";
  import Icon from "./ds/Icon.svelte";
  import ThreadMessage from "./ThreadMessage.svelte";
  import InlineReply, { type ReplySendData } from "./InlineReply.svelte";
  import PriorityIndicator from "./PriorityIndicator.svelte";
  import TriageBadges from "./TriageBadges.svelte";
  import type { Email, ThreadMsg } from "./data";
  import * as ipc from "./ipc";
  import type { BackendTriageLabel } from "./ipc";

  let {
    email,
    onClose,
    onSendReply,
    fullscreen,
    onToggleFullscreen,
    onToggleDone,
    onForward,
    replySignature,
    initialReplyOpen = 0,
    triageLabels = [],
    onSetTriageLabels,
    autoSummarize = false,
  }: {
    email: Email | undefined;
    onClose: () => void;
    onSendReply: (msg: ThreadMsg, data: ReplySendData) => void;
    replySignature?: string;
    fullscreen: boolean;
    onToggleFullscreen: (v: boolean) => void;
    onToggleDone: () => void;
    /** Forward the open thread's latest message (palette / message action). */
    onForward?: () => void;
    /** One-shot request counter: each bump opens the inline reply on the
     *  last message (palette Reply / 'r' shortcut). "last" resolves lazily
     *  because bodies load async. 0 = no request. */
    initialReplyOpen?: number;
    /** Jev triage label id→name lookup, for the classification badges shown
     *  under the subject. */
    triageLabels?: BackendTriageLabel[];
    /** Manual label edit (badges' "+" menu / ×). Omit to render read-only. */
    onSetTriageLabels?: (id: string, labelIds: string[]) => void;
    /** Auto-generate this thread's summary as soon as it's viewable, instead
     *  of waiting for an explicit "Summarize" click. */
    autoSummarize?: boolean;
  } = $props();

  // "last" = reply to the newest message once messages resolve (bodies are
  // fetched async — a concrete id picked too early would be the stub row's).
  let replyTargetId: string | null | "last" = $state(null);
  let expandedId: string | null = $state(null);

  const messages: ThreadMsg[] = $derived(
    email
      ? (email.thread ?? [
          {
            id: "m0",
            from: email.from,
            isMe: false,
            date: email.time,
            fullDate: email.fullDate,
            snippet: (email.html ? "" : (email.body ?? "")).slice(0, 90),
            body: email.body ?? "",
            html: email.html,
            attachments: email.attachments,
          },
        ])
      : [],
  );

  const activeReplyId = $derived(
    replyTargetId === "last" ? (messages[messages.length - 1]?.id ?? null) : replyTargetId,
  );

  // ------------------------------------------------------- AI thread summary
  // Same affordance as InboxList's group summary \u2014 runs on an explicit
  // click by default, or automatically once the thread opens when the user
  // has opted into "Auto-summarize" in Settings (DESIGN.md AI privacy rules).
  // Gated on a configured key, same check as Settings/InboxList.
  let aiConfigured = $state(false);
  if (ipc.isTauri) {
    ipc
      .aiStatus()
      .then((s) => (aiConfigured = s.configured))
      .catch(() => {});
  }

  interface ThreadSummary {
    /** Identifies exactly which messages this summary covers \u2014 a mismatch
     *  (new reply arrives) means the cached text is stale and the button
     *  reverts to "Summarize thread". */
    cacheKey: string;
    text: string;
    generating: boolean;
    error: string | null;
    open: boolean;
  }
  // ponytail: session-only, one thread open at a time \u2014 same non-durable
  // cache tradeoff as InboxList's group summaries.
  let threadSummary: ThreadSummary | null = $state(null);

  function threadSummaryCacheKey(id: string, msgs: ThreadMsg[]): string {
    return id + ":" + msgs.map((m) => m.id).join(",");
  }

  function messagePlainText(m: ThreadMsg): string {
    return (m.bodyText ?? (m.html ? m.body.replace(/<[^>]+>/g, " ") : m.body) ?? "").trim();
  }

  function toggleThreadSummary() {
    if (!threadSummary) return;
    threadSummary = { ...threadSummary, open: !threadSummary.open };
  }

  async function runThreadSummary(em: Email) {
    const cacheKey = threadSummaryCacheKey(em.id, messages);
    threadSummary = { cacheKey, text: "", generating: true, error: null, open: true };
    try {
      const items: ipc.ThreadSummaryItem[] = messages.map((m) => ({
        from: m.isMe ? "Me" : m.from,
        snippet: messagePlainText(m).slice(0, 600),
      }));
      const text = await ipc.summarizeThread("openai", em.subject, items);
      // The user may have switched to a different thread (or this thread's
      // messages changed) while the request was in flight \u2014 a newer call
      // already moved the cache key on, so drop this now-stale result
      // instead of clobbering the newer one (last-requested wins, not
      // last-resolved).
      if (threadSummary?.cacheKey !== cacheKey) return;
      threadSummary = { cacheKey, text, generating: false, error: null, open: true };
    } catch (err) {
      if (threadSummary?.cacheKey !== cacheKey) return;
      threadSummary = { cacheKey, text: "", generating: false, error: String(err), open: true };
    }
  }

  // Auto-summarize opt-in (Settings): kick off this thread's summary as soon
  // as it's viewable and isn't already cached/in flight for THIS thread.
  // Checking only cacheKey (not a bare `generating` flag) lets switching to
  // a new thread start its own request immediately, even if the previous
  // thread's request is still resolving in the background.
  $effect(() => {
    if (!aiConfigured || !autoSummarize || !email || messages.length <= 1) return;
    const key = threadSummaryCacheKey(email.id, messages);
    if (threadSummary?.cacheKey === key) return;
    runThreadSummary(email);
  });

  // Reset per-thread UI state only when the thread actually changes — the
  // email prop gets a new identity on every sync refresh, which must not
  // yank an open reply box (or resurrect a cancelled one). A false→true edge
  // on initialReplyOpen while the same thread stays open (palette Reply on
  // the open thread) opens the reply on the last message once.
  let lastEmailId: string | null = null;
  let lastReplyReq = 0;
  $effect(() => {
    const id = email?.id ?? null;
    const idChanged = id !== lastEmailId;
    const replyEdge = initialReplyOpen > 0 && initialReplyOpen !== lastReplyReq;
    lastEmailId = id;
    lastReplyReq = initialReplyOpen;
    if (idChanged) {
      replyTargetId = initialReplyOpen > 0 ? "last" : null;
      expandedId = messages.length ? messages[messages.length - 1].id : null;
    } else if (replyEdge) {
      replyTargetId = "last";
    }
  });
</script>

{#snippet content(em: Email)}
  <div class="content" class:fs={fullscreen}>
    <h1>{em.subject}</h1>
    {#if em.priority || em.triageLabelIds?.length || onSetTriageLabels}
      <div class="triage-header">
        <PriorityIndicator priority={em.priority} />
        <TriageBadges
          labelIds={em.triageLabelIds}
          {triageLabels}
          onToggleLabel={onSetTriageLabels
            ? (id) => {
                const current = em.triageLabelIds ?? [];
                const next = current.includes(id)
                  ? current.filter((x) => x !== id)
                  : [...current, id];
                onSetTriageLabels(em.id, next);
              }
            : undefined}
        />
      </div>
    {/if}
    {#if aiConfigured && messages.length > 1}
      {@const summaryKey = threadSummaryCacheKey(em.id, messages)}
      {@const summaryReady = threadSummary?.cacheKey === summaryKey}
      <div class="thread-summary-row">
        {#if summaryReady && threadSummary}
          <button
            type="button"
            class="summary-toggle"
            disabled={threadSummary.generating}
            onclick={toggleThreadSummary}
          >
            {threadSummary.generating ? "Summarizing\u2026" : threadSummary.open ? "Hide summary" : "Show summary"}
          </button>
        {:else}
          <button type="button" class="summary-toggle" onclick={() => runThreadSummary(em)}>
            Summarize thread
          </button>
        {/if}
      </div>
      {#if summaryReady && threadSummary && threadSummary.open}
        <div class="summary-block" class:is-error={!!threadSummary.error}>
          {threadSummary.generating ? "Summarizing\u2026" : (threadSummary.error ?? threadSummary.text)}
        </div>
      {/if}
    {/if}
    <div>
      {#each messages as m (m.id)}
        <ThreadMessage
          msg={m}
          accountId={em.accountId}
          accountTag={em.accountTag}
          expanded={expandedId === m.id}
          onToggle={() => (expandedId = expandedId === m.id ? null : m.id)}
          showActions={activeReplyId !== m.id}
          onReply={() => (replyTargetId = m.id)}
          onReplyAll={() => (replyTargetId = m.id)}
          onForward={() => onForward?.()}
        />
        {#if activeReplyId === m.id}
          <div class="reply-card">
            <InlineReply
              toName={m.isMe ? em.from : m.from}
              signature={replySignature}
              history={messages}
              onCancel={() => (replyTargetId = null)}
              onSend={(data) => onSendReply(m, data)}
            />
          </div>
        {/if}
      {/each}
    </div>
  </div>
{/snippet}

{#if email}
  {#if fullscreen}
    <div class="fs-overlay">
      <div class="fs-header-wrap">
        <div class="fs-header">
          <Tooltip label="Back" side="bottom">
            <IconButton label="Back" onclick={onClose}>
              <Icon d="M15 18l-6-6 6-6" size={15} />
            </IconButton>
          </Tooltip>
          <div class="spacer"></div>
          <Tooltip label={email.done ? "Mark not done" : "Mark done"} side="bottom">
            <IconButton label="Mark done" onclick={onToggleDone}>
              {#if email.done}
                <Icon d="M20 6L9 17l-5-5" size={15} strokeWidth={2.2} stroke="var(--tag-mint-fg)" />
              {:else}
                <Icon d="M20 6L9 17l-5-5" size={15} />
              {/if}
            </IconButton>
          </Tooltip>
          <Tooltip label="Delete" side="bottom">
            <IconButton label="Delete">
              <Icon d="M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13" size={15} />
            </IconButton>
          </Tooltip>
          <Tooltip label="Exit full screen" side="bottom">
            <IconButton label="Exit full screen" onclick={() => onToggleFullscreen(false)}>
              <Icon d="M9 4H5a1 1 0 00-1 1v4M15 4h4a1 1 0 011 1v4M9 20H5a1 1 0 01-1-1v-4M15 20h4a1 1 0 001-1v-4" size={15} />
            </IconButton>
          </Tooltip>
        </div>
      </div>
      <div class="fs-scroll">{@render content(email)}</div>
    </div>
  {:else}
    {@render content(email)}
  {/if}
{/if}

<style>
  .content h1 {
    font-family: var(--font-display);
    font-size: 21px;
    font-weight: 700;
    color: var(--text-primary);
    margin: 0 0 18px;
  }
  .triage-header {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    margin: -10px 0 18px;
  }
  .thread-summary-row {
    margin: -10px 0 10px;
  }
  .summary-toggle {
    border: none;
    background: none;
    padding: 0;
    font-family: var(--font-body);
    font-size: 11px;
    font-weight: 600;
    color: var(--text-tertiary);
    cursor: pointer;
  }
  .summary-toggle:hover:not(:disabled) {
    color: var(--text-secondary);
  }
  .summary-toggle:disabled {
    cursor: default;
    opacity: 0.6;
  }
  /* Deliberately short and boxed \u2014 a few lines, never a scrolling essay,
     regardless of how much the model returns (the prompt asks for brevity
     too, this is the visual backstop). Same treatment as InboxList's group
     summary block. */
  .summary-block {
    margin-bottom: 18px;
    padding: 8px 10px;
    border-radius: var(--radius-md);
    background: var(--surface-sunken);
    font-family: var(--font-body);
    font-size: 12px;
    line-height: 1.5;
    color: var(--text-secondary);
    white-space: pre-line;
    max-height: 4.6em;
    overflow: hidden;
  }
  .summary-block.is-error {
    color: var(--state-danger);
  }
  .content.fs {
    padding: 0 28px;
    max-width: 720px;
    margin: 0 auto;
  }
  .reply-card {
    margin: 0 -16px 8px;
    background: var(--surface-card);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-md);
    border: 1px solid var(--border-subtle);
    overflow: hidden;
    padding: 0 16px 14px;
  }
  .fs-overlay {
    position: fixed;
    inset: 0;
    z-index: 70;
    background: var(--surface-card);
    display: flex;
    flex-direction: column;
  }
  .fs-header-wrap {
    padding: 18px 28px 0;
  }
  .fs-header {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-bottom: 20px;
  }
  .spacer {
    flex: 1;
  }
  .fs-scroll {
    overflow-y: auto;
    flex: 1;
    padding: 0 0 40px;
  }
</style>
