<script lang="ts">
  import IconButton from "./ds/IconButton.svelte";
  import Tooltip from "./ds/Tooltip.svelte";
  import Icon from "./ds/Icon.svelte";
  import ThreadMessage from "./ThreadMessage.svelte";
  import InlineReply from "./InlineReply.svelte";
  import type { Email, ThreadMsg } from "./data";

  let {
    email,
    onClose,
    onSendReply,
    fullscreen,
    onToggleFullscreen,
    onToggleDone,
  }: {
    email: Email | undefined;
    onClose: () => void;
    onSendReply: (msg: ThreadMsg, body: string) => void;
    fullscreen: boolean;
    onToggleFullscreen: (v: boolean) => void;
    onToggleDone: () => void;
  } = $props();

  let replyTargetId: string | null = $state(null);
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

  // Reset per-thread UI state when the email changes (mirrors prototype effect on email.id).
  $effect(() => {
    void email?.id;
    replyTargetId = null;
    expandedId = messages.length ? messages[messages.length - 1].id : null;
  });
</script>

{#snippet content(em: Email)}
  <div class="content" class:fs={fullscreen}>
    <h1>{em.subject}</h1>
    <div>
      {#each messages as m (m.id)}
        <ThreadMessage
          msg={m}
          accountId={em.accountId}
          expanded={expandedId === m.id}
          onToggle={() => (expandedId = expandedId === m.id ? null : m.id)}
          showActions={replyTargetId !== m.id}
          onReply={() => (replyTargetId = m.id)}
          onReplyAll={() => (replyTargetId = m.id)}
          onForward={() => {}}
        />
        {#if replyTargetId === m.id}
          <div class="reply-card">
            <InlineReply
              toName={m.isMe ? em.from : m.from}
              onCancel={() => (replyTargetId = null)}
              onSend={(body) => onSendReply(m, body)}
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
