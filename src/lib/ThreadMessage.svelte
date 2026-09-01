<script lang="ts">
  import IconButton from "./ds/IconButton.svelte";
  import Tooltip from "./ds/Tooltip.svelte";
  import Icon from "./ds/Icon.svelte";
  import HtmlEmailFrame from "./HtmlEmailFrame.svelte";
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

  // Split a plaintext body into main content and a trailing quoted block:
  // a trailing run of '> ' lines (blank lines allowed inside), optionally
  // preceded by an 'On <...> wrote:' intro line. Returns null when there is
  // no trailing quote or no non-quoted content before it — never hide
  // non-quoted content.
  function splitQuoted(body: string): { main: string; quoted: string } | null {
    const lines = body.split("\n");
    let i = lines.length;
    let hasQuote = false;
    while (i > 0) {
      const l = lines[i - 1];
      if (/^\s*>/.test(l)) {
        hasQuote = true;
        i--;
      } else if (l.trim() === "") {
        i--;
      } else {
        break;
      }
    }
    if (!hasQuote || i === lines.length) return null;
    if (i > 0 && /^On\s.+wrote:\s*$/.test(lines[i - 1])) i--;
    const main = lines.slice(0, i).join("\n").replace(/\s+$/, "");
    if (!main.trim()) return null;
    return { main, quoted: lines.slice(i).join("\n").trim() };
  }

  const split = $derived(msg.html ? null : splitQuoted(msg.body));
  let quoteOpen = $state(false);
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
          {#if accountId?.includes("@")}
            <span class="head-to">
              {#if accountTag}<span class="head-to-dot" style:background="var(--tag-{accountTag}-fg)"></span>{/if}
              to {accountId}
            </span>
          {/if}
        </span>
      </span>
      <span class="head-date">{msg.fullDate ?? msg.date}</span>
    </div>
    {#if msg.html}
      <!-- HTML mail renders edge-to-edge; the card padding stays for text. -->
      <div class="html-bleed">
        <HtmlEmailFrame html={msg.body} />
      </div>
    {:else if split}
      <div class="body">{split.main}</div>
      <button
        class="quote-pill"
        type="button"
        class:open={quoteOpen}
        aria-label={quoteOpen ? "Hide quoted text" : "Show quoted text"}
        onclick={() => (quoteOpen = !quoteOpen)}>···</button
      >
      {#if quoteOpen}
        <div class="body quoted">{split.quoted}</div>
      {/if}
    {:else}
      <div class="body">{msg.body}</div>
    {/if}
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
  .html-bleed {
    margin: 0 -16px -12px;
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
  .body {
    font-family: var(--font-body);
    font-size: 15px;
    line-height: 1.6;
    color: var(--text-secondary);
    white-space: pre-wrap;
  }
  .body.quoted {
    color: var(--text-tertiary);
    margin-top: 8px;
  }
  .quote-pill {
    display: inline-block;
    margin-top: 10px;
    padding: 0 10px;
    border: 1px solid var(--border-subtle);
    border-radius: 999px;
    background: var(--surface-sunken, #ececec);
    color: var(--text-tertiary);
    font-family: var(--font-mono);
    font-size: 12px;
    line-height: 18px;
    letter-spacing: 1px;
    cursor: pointer;
  }
  .quote-pill.open {
    background: var(--border-subtle);
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
