<script lang="ts">
  import IconButton from "./ds/IconButton.svelte";
  import Icon from "./ds/Icon.svelte";

  let {
    toName,
    onCancel,
    onSend,
  }: {
    toName: string;
    onCancel: () => void;
    onSend: () => void;
  } = $props();

  let sent = $state(false);
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
  <div class="reply">
    <div class="to">To: {toName}</div>
    <!-- svelte-ignore a11y_autofocus -->
    <textarea bind:this={bodyEl} onselect={onBodySelect} autofocus placeholder="Reply to {toName}…" rows="6"
    ></textarea>
    {#if selPos}
      <div bind:this={selRoot} class="sel-toolbar" style:top="{selPos.top}px" style:left="{selPos.left}px">
        {@render toolbar()}
      </div>
    {/if}
    <div class="actions">
      <button class="send" onclick={send}>
        <Icon d="M4 20l1-4L17 4l3 3L8 19l-4 1z" size={14} />
        Send
      </button>
      <IconButton size="sm" label="Discard" onclick={onCancel}>
        <Icon d="M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13" size={14} />
      </IconButton>
      <div class="vr"></div>
      <IconButton size="sm" label="Attach file">
        <Icon d="M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9" size={14} />
      </IconButton>
      <div bind:this={aaRoot} class="aa-root">
        <button class="aa" class:on={showFormat} title="Formatting" onclick={() => (showFormat = !showFormat)}>Aa</button>
        {#if showFormat}
          <div class="format-popup">{@render toolbar()}</div>
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .sent {
    padding: 14px 0;
    font-family: var(--font-body);
    font-size: 13.5px;
    color: var(--text-tertiary);
    border-top: 1px solid var(--border-subtle);
  }
  .reply {
    margin-top: 20px;
    padding-top: 16px;
  }
  .to {
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-tertiary);
  }
  textarea {
    width: 100%;
    box-sizing: border-box;
    border: none;
    outline: none;
    resize: none;
    padding: 16px 0 0;
    font-family: var(--font-body);
    font-size: 14px;
    color: var(--text-primary);
    background: none;
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
  .actions {
    display: flex;
    align-items: center;
    gap: 8px;
    padding-top: 14px;
    border-top: 1px solid var(--border-subtle);
    margin-top: 14px;
  }
  .send {
    border: none;
    background: var(--navy-900);
    color: var(--text-inverse);
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 8px;
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
    margin: 0 4px;
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
