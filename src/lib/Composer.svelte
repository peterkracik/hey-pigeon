<script lang="ts">
  import IconButton from "./ds/IconButton.svelte";
  import Icon from "./ds/Icon.svelte";
  import RecipientField from "./RecipientField.svelte";

  let {
    onClose,
    onSend,
  }: {
    onClose: () => void;
    onSend: () => void;
  } = $props();

  let sent = $state(false);
  let showCc = $state(false);
  let attachments: string[] = $state([]);
  let showFormat = $state(false);
  let selPos: { top: number; left: number } | null = $state(null);
  let aaRoot: HTMLDivElement | undefined = $state();
  let selRoot: HTMLDivElement | undefined = $state();
  let bodyEl: HTMLTextAreaElement | undefined = $state();

  const FORMAT_OPTIONS: [string, string][] = [
    ["M7 5h6a3.5 3.5 0 010 7H7zM7 12h7a3.5 3.5 0 010 7H7z", "Bold"],
    ["M10 5h7M7 19h7M13.5 5L9.5 19", "Italic"],
    ["M6 5v6a6 6 0 0012 0V5M4 19h16", "Underline"],
    ["M4 12h16M8 6.5c0-1.5 2-2.5 4-2.5s4.5 1 4.5 3-2 2.5-4.5 3-4.5 1.5-4.5 3.5 2 3 4.5 3 4-1 4-2.5", "Strikethrough"],
    ["M10 14a3.5 3.5 0 005 0l3-3a3.5 3.5 0 00-5-5l-1 1M14 10a3.5 3.5 0 00-5 0l-3 3a3.5 3.5 0 005 5l1-1", "Link"],
    ["M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01", "Bulleted list"],
  ];

  function onDocMousedown(ev: MouseEvent) {
    const t = ev.target as Node;
    if (showFormat && aaRoot && !aaRoot.contains(t)) showFormat = false;
    if (selPos && selRoot && !selRoot.contains(t) && t !== bodyEl) selPos = null;
  }

  function onBodySelect() {
    if (!bodyEl || bodyEl.selectionStart === bodyEl.selectionEnd) {
      selPos = null;
      return;
    }
    const rect = bodyEl.getBoundingClientRect();
    selPos = { top: rect.top - 46, left: rect.left };
  }

  function send() {
    sent = true;
    setTimeout(() => {
      sent = false;
      onSend();
    }, 700);
  }
</script>

<svelte:document onmousedown={onDocMousedown} />

{#snippet toolbar()}
  {#each FORMAT_OPTIONS as [d, label] (label)}
    <IconButton size="sm" {label}>
      <Icon {d} size={14} />
    </IconButton>
  {/each}
{/snippet}

{#if sent}
  <div class="sent">Message sent</div>
{:else}
  <div class="field-row">
    <span class="field-label">To</span>
    <RecipientField />
    {#if !showCc}
      <button class="cc-toggle" onclick={() => (showCc = true)}>Cc/Bcc</button>
    {/if}
  </div>
  {#if showCc}
    <div class="field-row">
      <span class="field-label">Cc</span>
      <RecipientField />
    </div>
    <div class="field-row">
      <span class="field-label">Bcc</span>
      <RecipientField />
    </div>
  {/if}
  <div class="field-row bordered">
    <span class="field-label">Subject</span>
    <input class="subject" />
  </div>
  <textarea bind:this={bodyEl} onselect={onBodySelect} placeholder="Write your message..." rows="14"></textarea>
  {#if selPos}
    <div bind:this={selRoot} class="sel-toolbar" style:top="{selPos.top}px" style:left="{selPos.left}px">
      {@render toolbar()}
    </div>
  {/if}
  {#if attachments.length > 0}
    <div class="chips">
      {#each attachments as a, i (a)}
        <span class="chip">
          <Icon d="M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9" size={14} />
          {a}
          <button class="chip-x" onclick={() => (attachments = attachments.filter((_, j) => j !== i))}>
            <Icon d="M6 6l12 12M18 6L6 18" size={14} />
          </button>
        </span>
      {/each}
    </div>
  {/if}
  <div class="footer">
    <button class="send" onclick={send}>
      <Icon d="M4 20l1-4L17 4l3 3L8 19l-4 1z" size={14} />
      Send
    </button>
    <IconButton size="sm" label="Discard" onclick={onClose}>
      <Icon d="M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13" size={14} />
    </IconButton>
    <div class="vr"></div>
    <IconButton size="sm" label="Send later">
      <Icon d="M12 7v5l3 3M12 22a10 10 0 100-20 10 10 0 000 20z" size={14} />
    </IconButton>
    <IconButton
      size="sm"
      label="Attach file"
      onclick={() => (attachments = [...attachments, "file-" + (attachments.length + 1) + ".pdf"])}
    >
      <Icon d="M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9" size={14} />
    </IconButton>
    <div bind:this={aaRoot} class="aa-root">
      <button class="aa" class:on={showFormat} title="Formatting" onclick={() => (showFormat = !showFormat)}>Aa</button>
      {#if showFormat}
        <div class="format-popup">{@render toolbar()}</div>
      {/if}
    </div>
  </div>
{/if}

<style>
  .sent {
    font-family: var(--font-body);
    font-size: 14px;
    color: var(--text-secondary);
    padding: var(--space-8) 0;
    text-align: center;
    border-top: 1px solid var(--border-subtle);
  }
  .field-row {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 7px 0;
  }
  .field-row.bordered {
    border-bottom: 1px solid var(--border-subtle);
  }
  .field-label {
    width: 46px;
    flex-shrink: 0;
    font-family: var(--font-body);
    font-size: 14px;
    color: var(--text-tertiary);
  }
  .cc-toggle {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    font-family: var(--font-body);
    font-size: 13px;
    flex-shrink: 0;
  }
  .subject {
    border: none;
    outline: none;
    background: none;
    flex: 1;
    font-family: var(--font-body);
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
  }
  textarea {
    border: none;
    outline: none;
    padding: 24px 0 13px;
    font-family: var(--font-body);
    font-size: 14px;
    color: var(--text-primary);
    width: 100%;
    background: none;
    box-sizing: border-box;
    resize: none;
    flex: 1;
    min-height: 260px;
  }
  .sel-toolbar {
    position: fixed;
    display: flex;
    gap: 2px;
    padding: 6px;
    background: var(--surface-card);
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-md);
    z-index: 20;
  }
  .chips {
    display: flex;
    gap: var(--space-2);
    flex-wrap: wrap;
    padding: 0 0 var(--space-3);
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 10px;
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-md);
    font-family: var(--font-body);
    font-size: 12.5px;
    color: var(--text-secondary);
  }
  .chip-x {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    display: flex;
    padding: 0;
  }
  .footer {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: 14px 0;
    border-top: 1px solid var(--border-subtle);
    position: sticky;
    bottom: 0;
    background: var(--surface-card);
  }
  .send {
    border: none;
    background: var(--navy-900);
    color: var(--text-inverse);
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: 8px 18px;
    border-radius: var(--radius-pill);
    font-family: var(--font-body);
    font-weight: 600;
    font-size: 13.5px;
  }
  .vr {
    width: 1px;
    height: 20px;
    background: var(--border-subtle);
    margin: 0 var(--space-1);
  }
  .aa-root {
    position: relative;
  }
  .aa {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    display: flex;
    padding: 6px;
    border-radius: var(--radius-sm);
    font-family: var(--font-body);
    font-size: 13px;
    font-weight: 600;
  }
  .aa.on,
  .aa:hover {
    color: var(--text-primary);
  }
  .format-popup {
    position: absolute;
    bottom: calc(100% + 8px);
    left: 0;
    display: flex;
    gap: 2px;
    padding: 6px;
    background: var(--surface-card);
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-md);
    z-index: 10;
  }
</style>
