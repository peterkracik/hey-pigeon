<script lang="ts">
  import IconButton from "./ds/IconButton.svelte";
  import Tooltip from "./ds/Tooltip.svelte";
  import Icon from "./ds/Icon.svelte";
  import EmailBody from "./EmailBody.svelte";
  import Avatar from "./ds/Avatar.svelte";
  import type { ThreadMsg } from "./data";

  let {
    msg,
    accountId,
    accountTag,
    expanded,
    onToggle,
    showActions,
    onReply,
    onReplyAll,
    onForward,
  }: {
    msg: ThreadMsg;
    accountId?: string;
    accountTag?: string;
    expanded: boolean;
    onToggle: () => void;
    showActions: boolean;
    onReply: () => void;
    onReplyAll: () => void;
    onForward: () => void;
  } = $props();

  const name = $derived(msg.isMe ? "Me" : msg.from);


</script>

{#snippet avatar(size: number)}
  <Avatar email={msg.fromAddr} {accountId} {name} {size} />
{/snippet}

{#if !expanded}
  <div class="row" onclick={onToggle} role="button" tabindex="0" onkeydown={(e) => e.key === "Enter" && onToggle()}>
    {@render avatar(26)}
    <span class="row-name">{name}</span>
    <span class="row-snippet">{msg.snippet}</span>
    <span class="row-date">{msg.date}</span>
  </div>
{:else}
  <div class="card">
    <div class="card-head" onclick={onToggle} role="button" tabindex="0" onkeydown={(e) => e.key === "Enter" && onToggle()}>
      <span class="head-left">
        {@render avatar(30)}
        <span class="head-text">
          <span class="head-name">{name}</span>
          {#if msg.to?.length}
            <span class="head-to" title="to {msg.to.join(', ')}">
              {#if accountTag}<span class="head-to-dot" style:background="var(--tag-{accountTag}-fg)"></span>{/if}
              to {msg.to.join(", ")}
            </span>
          {:else if accountId?.includes("@")}
            <span class="head-to">
              {#if accountTag}<span class="head-to-dot" style:background="var(--tag-{accountTag}-fg)"></span>{/if}
              to {accountId}
            </span>
          {/if}
        </span>
      </span>
      <span class="head-date">{msg.fullDate ?? msg.date}</span>
    </div>
    <EmailBody html={Boolean(msg.html)} body={msg.body} />
    {#if msg.attachments && msg.attachments.length > 0}
      <div class="attachments">
        {#each msg.attachments as a (a.name)}
          <a download href="#top" class="chip">
            <Icon d="M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9" size={15} />
            <span class="chip-name">{a.name}</span>
            <span class="chip-size">{a.size}</span>
          </a>
        {/each}
      </div>
    {/if}
    {#if showActions}
      <div class="msg-actions">
        <Tooltip label="Reply" side="top">
          <IconButton size="sm" label="Reply" onclick={onReply}>
            <Icon d="M9 17l-5-5 5-5M4 12h11a5 5 0 010 10h-1" size={15} />
          </IconButton>
        </Tooltip>
        <Tooltip label="Reply all" side="top">
          <IconButton size="sm" label="Reply all" onclick={onReplyAll}>
            <Icon d="M13 17l-5-5 5-5M6 17l-5-5 5-5M1 12h14a5 5 0 010 10h-1" size={15} />
          </IconButton>
        </Tooltip>
        <Tooltip label="Forward" side="top">
          <IconButton size="sm" label="Forward" onclick={onForward}>
            <Icon d="M15 17l5-5-5-5M20 12H9a5 5 0 000 10h1" size={15} />
          </IconButton>
        </Tooltip>
      </div>
    {/if}
  </div>
{/if}

<style>
  .row {
    display: flex;
    align-items: center;
    gap: 12px;
    box-sizing: border-box;
    padding: 11px 16px;
    margin: 0 -16px;
    border-radius: var(--radius-md);
    cursor: pointer;
    border: 1px solid transparent;
    transition:
      background 120ms,
      box-shadow 120ms;
  }
  .row:hover {
    background: var(--surface-card);
    box-shadow: var(--shadow-xs);
    border-color: var(--border-subtle);
  }
  .row-name {
    width: 110px;
    flex-shrink: 0;
    font-family: var(--font-body);
    font-size: 14px;
    font-weight: 500;
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row-snippet {
    flex: 1;
    font-family: var(--font-body);
    font-size: 14px;
    color: var(--text-tertiary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row-date {
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }
  .card {
    margin: 0 -16px 8px;
    background: var(--surface-card);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-md);
    border: 1px solid var(--border-subtle);
    overflow: hidden;
    padding: 20px 16px 12px;
  }
  .card-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
    cursor: pointer;
  }
  .head-left {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .head-text {
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .head-name {
    font-family: var(--font-body);
    font-size: 14.5px;
    font-weight: 700;
    color: var(--text-primary);
  }
  .head-to {
    display: flex;
    align-items: center;
    gap: 5px;
    font-family: var(--font-body);
    font-size: 12px;
    color: var(--text-tertiary);
    max-width: 480px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .head-to-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .head-date {
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--text-tertiary);
  }
  .attachments {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    margin-top: 24px;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-md);
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-secondary);
    text-decoration: none;
  }
  .chip:hover {
    text-decoration: none;
  }
  .chip-name {
    font-weight: 600;
    color: var(--text-primary);
  }
  .chip-size {
    color: var(--text-tertiary);
  }
  .msg-actions {
    display: flex;
    gap: 2px;
    margin-top: 14px;
  }
</style>
