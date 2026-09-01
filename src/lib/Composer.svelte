<script lang="ts">
  import { onDestroy } from "svelte";
  import IconButton from "./ds/IconButton.svelte";
  import Icon from "./ds/Icon.svelte";
  import RecipientField from "./RecipientField.svelte";
  import AiEditPopover from "./AiEditPopover.svelte";
  import { toast } from "./toast.svelte";
  import type { Account } from "./data";

  export interface ComposeData {
    accountId: string;
    to: string[];
    cc: string[];
    bcc: string[];
    subject: string;
    /** Plain-text body (always present — the MIME text part). */
    body: string;
    /** Rich body when formatting was applied — the MIME html part. */
    bodyHtml?: string;
    attachments?: { filename: string; mime_type: string; size: number; data_b64: string }[];
  }

  interface Chip {
    name: string;
    email: string;
  }

  let {
    onClose,
    onSend,
    accounts = [],
    initialAccountId,
    initialDraft,
  }: {
    onClose: () => void;
    onSend: (data: ComposeData) => void;
    accounts?: Account[];
    initialAccountId?: string;
    // Restores a cancelled send (undo) — prefills all fields.
    initialDraft?: ComposeData;
  } = $props();

  const chipsFrom = (addrs: string[]): Chip[] => addrs.map((email) => ({ name: email, email }));

  let sent = $state(false);
  // The "Message sent" flash timer calls onClose(); if the instance is
  // destroyed first (send-undo remounts via {#key}), a stale fire would
  // close the restored composer and wipe the draft — cancel on destroy.
  let sentFlashTimer: ReturnType<typeof setTimeout> | undefined;
  onDestroy(() => clearTimeout(sentFlashTimer));
  // Draft restore intentionally captures only the initial value — the user
  // owns the fields after mount ({#key} remounts on a new restored draft).
  // svelte-ignore state_referenced_locally
  let showCc = $state(Boolean(initialDraft && (initialDraft.cc.length || initialDraft.bcc.length)));
  // svelte-ignore state_referenced_locally
  let toChips: Chip[] = $state(chipsFrom(initialDraft?.to ?? []));
  // svelte-ignore state_referenced_locally
  let ccChips: Chip[] = $state(chipsFrom(initialDraft?.cc ?? []));
  // svelte-ignore state_referenced_locally
  let bccChips: Chip[] = $state(chipsFrom(initialDraft?.bcc ?? []));
  // svelte-ignore state_referenced_locally
  let subject = $state(initialDraft?.subject ?? "");
  // From defaults to the viewed account filter (if any), else the first account.
  // svelte-ignore state_referenced_locally
  let fromId = $state(initialDraft?.accountId ?? initialAccountId ?? accounts[0]?.id ?? "");
  const fromAccount = $derived(accounts.find((a) => a.id === fromId));

  const prefillFor = (sig?: string) => (sig ? `\n\n${sig}` : "");
  const esc = (t: string) =>
    t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  /** Plain text → editor HTML (escaped, newlines as <br>). */
  const textToHtml = (t: string) => esc(t).replace(/\n/g, "<br>");
  // Prefill once at mount — the user owns the body afterwards. Switching the
  // From account only swaps the signature while the body is still pristine.
  // The editor is contenteditable; `body` mirrors its innerHTML (updated on
  // input — programmatic writes update both together).
  // svelte-ignore state_referenced_locally
  let body = $state(
    initialDraft?.bodyHtml ??
      textToHtml(
        initialDraft?.body ??
          prefillFor(
            accounts.find((a) => a.id === (initialAccountId ?? accounts[0]?.id))?.signature,
          ),
      ),
  );

  /** Svelte action: seed the editor's HTML once at mount. */
  function initBody(el: HTMLDivElement) {
    el.innerHTML = body;
    // Force tag output (<b>, not <span style="font-weight:...">) so the
    // formatted-content check in send() sees what execCommand produced.
    document.execCommand("styleWithCSS", false, "false");
  }

  /** Paste as plain text — clipboard HTML (styles, trackers, arbitrary
   * attributes) must never ride into an outgoing message unsanitized;
   * formatting is applied via the toolbar only. */
  function onPaste(ev: ClipboardEvent) {
    ev.preventDefault();
    const text = ev.clipboardData?.getData("text/plain") ?? "";
    if (text) document.execCommand("insertText", false, text);
  }

  function setBody(html: string) {
    body = html;
    if (bodyEl) bodyEl.innerHTML = html;
  }

  function switchFrom(id: string) {
    const prev = accounts.find((a) => a.id === fromId);
    const next = accounts.find((a) => a.id === id);
    if (body === textToHtml(prefillFor(prev?.signature)))
      setBody(textToHtml(prefillFor(next?.signature)));
    fromId = id;
  }
  // Real attachments: name/type/size + base64 content, MIME-ready.
  interface ComposeAttachment {
    filename: string;
    mime_type: string;
    size: number;
    data_b64: string;
  }
  // svelte-ignore state_referenced_locally
  let attachments: ComposeAttachment[] = $state(initialDraft?.attachments ?? []);
  let fileInput: HTMLInputElement | undefined = $state();

  // Gmail caps the ENCODED message at 25 MB; base64 inflates ~33%, so cap
  // raw attachment bytes at 18 MB total. Blocked extensions (.exe …) are
  // left to Gmail — its server-side rejection surfaces via the send toast.
  const MAX_ATTACH_BYTES = 18 * 1024 * 1024;

  const fmtSize = (n: number) =>
    n >= 1024 * 1024 ? `${(n / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`;

  async function addFiles(list: FileList | null) {
    if (!list) return;
    let total = attachments.reduce((s, a) => s + a.size, 0);
    for (const f of list) {
      if (total + f.size > MAX_ATTACH_BYTES) {
        toast("danger", "Attachment too large", `Gmail's limit is ~18 MB per message — “${f.name}” does not fit`);
        continue;
      }
      // readAsDataURL handles binary safely; strip the data:...;base64, prefix.
      const data_b64 = await new Promise<string>((resolve, reject) => {
        const r = new FileReader();
        r.onload = () => resolve(String(r.result).split(",", 2)[1] ?? "");
        r.onerror = () => reject(r.error);
        r.readAsDataURL(f);
      }).catch(() => null);
      if (data_b64 === null) {
        toast("danger", "Could not read file", f.name);
        continue;
      }
      total += f.size;
      attachments = [
        ...attachments,
        { filename: f.name, mime_type: f.type || "application/octet-stream", size: f.size, data_b64 },
      ];
    }
  }
  let dragging = $state(false);
  let dragDepth = 0;
  function onDragEnter(ev: DragEvent) {
    if (!ev.dataTransfer?.types.includes("Files")) return;
    ev.preventDefault();
    dragDepth++;
    dragging = true;
  }
  function onDragLeave(ev: DragEvent) {
    if (!dragging) return;
    ev.preventDefault();
    if (--dragDepth <= 0) {
      dragDepth = 0;
      dragging = false;
    }
  }
  function onDrop(ev: DragEvent) {
    if (!dragging) return;
    ev.preventDefault();
    dragDepth = 0;
    dragging = false;
    addFiles(ev.dataTransfer?.files ?? null);
  }
  let fromOpen = $state(false);
  let fromRoot: HTMLDivElement | undefined = $state();
  let showFormat = $state(false);
  let selPos: { top: number; left: number } | null = $state(null);
  let aaRoot: HTMLDivElement | undefined = $state();
  let selRoot: HTMLDivElement | undefined = $state();
  let bodyEl: HTMLDivElement | undefined = $state();

  const FORMAT_OPTIONS: [string, string, string][] = [
    ["M7 5h6a3.5 3.5 0 010 7H7zM7 12h7a3.5 3.5 0 010 7H7z", "Bold", "bold"],
    ["M10 5h7M7 19h7M13.5 5L9.5 19", "Italic", "italic"],
    ["M6 5v6a6 6 0 0012 0V5M4 19h16", "Underline", "underline"],
    ["M4 12h16M8 6.5c0-1.5 2-2.5 4-2.5s4.5 1 4.5 3-2 2.5-4.5 3-4.5 1.5-4.5 3.5 2 3 4.5 3 4-1 4-2.5", "Strikethrough", "strikeThrough"],
    ["M10 14a3.5 3.5 0 005 0l3-3a3.5 3.5 0 00-5-5l-1 1M14 10a3.5 3.5 0 00-5 0l-3 3a3.5 3.5 0 005 5l1-1", "Link", "link"],
    ["M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01", "Bulleted list", "insertUnorderedList"],
  ];

  // Link popover: saves the selection Range (the input steals focus, which
  // collapses it), asks for a URL, then restores the range and links it.
  let linkPos: { top: number; left: number } | null = $state(null);
  let linkUrl = $state("");
  let linkRoot: HTMLDivElement | undefined = $state();
  let savedRange: Range | null = null;

  function openLink() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !bodyEl || !bodyEl.contains(sel.anchorNode)) {
      toast("info", "Select text first", "Select the text to turn into a link");
      return;
    }
    savedRange = sel.getRangeAt(0).cloneRange();
    const text = sel.toString().trim();
    // URL-shaped selection prefills the field.
    linkUrl = /^https?:\/\/\S+$/i.test(text) || /^[\w-]+(\.[\w-]+)+(\/\S*)?$/.test(text) ? text : "";
    const rect = savedRange.getBoundingClientRect();
    linkPos = { top: rect.bottom + 8, left: rect.left };
    selPos = null;
  }

  function closeLink() {
    linkPos = null;
    savedRange = null;
    linkUrl = "";
  }

  function applyLink() {
    const raw = linkUrl.trim();
    if (!raw || !savedRange) return;
    const url = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
    const sel = window.getSelection();
    sel?.removeAllRanges();
    sel?.addRange(savedRange);
    document.execCommand("createLink", false, url);
    if (bodyEl) body = bodyEl.innerHTML;
    closeLink();
  }

  // AI popover: same saved-Range trick as the link popover (opening the
  // popover steals focus, collapsing the editor's selection). No selection
  // means "operate on the whole body".
  let aiSavedRange: Range | null = null;

  function aiGetTarget() {
    const sel = window.getSelection();
    const hasSelection = !!(sel && !sel.isCollapsed && bodyEl && bodyEl.contains(sel.anchorNode));
    aiSavedRange = hasSelection ? sel!.getRangeAt(0).cloneRange() : null;
    selPos = null;
    return { text: hasSelection ? sel!.toString() : (bodyEl?.innerText ?? ""), hasSelection };
  }

  function aiApply(result: string) {
    if (aiSavedRange) {
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(aiSavedRange);
      document.execCommand("insertText", false, result);
      if (bodyEl) body = bodyEl.innerHTML;
    } else {
      setBody(textToHtml(result));
    }
  }

  /** Apply a toolbar command to the current editor selection. */
  function exec(cmd: string) {
    if (cmd === "link") {
      openLink();
      return;
    }
    bodyEl?.focus();
    document.execCommand(cmd);
    if (bodyEl) body = bodyEl.innerHTML;
  }

  // Cmd/Ctrl+B/I/U — WKWebView has no default Edit-menu bindings for these
  // in contenteditable, so wire them to the same toolbar commands.
  const SHORTCUT_CMDS: Record<string, string> = { b: "bold", i: "italic", u: "underline" };
  function onBodyKeydown(ev: KeyboardEvent) {
    if (!(ev.metaKey || ev.ctrlKey)) return;
    const cmd = SHORTCUT_CMDS[ev.key.toLowerCase()];
    if (!cmd) return;
    ev.preventDefault();
    exec(cmd);
  }

  function onDocMousedown(ev: MouseEvent) {
    const t = ev.target as Node;
    if (showFormat && aaRoot && !aaRoot.contains(t)) showFormat = false;
    if (selPos && selRoot && !selRoot.contains(t) && t !== bodyEl) selPos = null;
    if (fromOpen && fromRoot && !fromRoot.contains(t)) fromOpen = false;
    if (linkPos && linkRoot && !linkRoot.contains(t)) closeLink();
  }

  function onBodySelect() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !bodyEl || !bodyEl.contains(sel.anchorNode)) {
      selPos = null;
      return;
    }
    const rect = sel.getRangeAt(0).getBoundingClientRect();
    selPos = { top: rect.top - 46, left: rect.left };
  }

  function send() {
    if (!toChips.length && !ccChips.length && !bccChips.length) {
      toast("danger", "Could not send", "Add at least one recipient");
      return;
    }
    // Optimistic: hand the data over immediately (outbox handles retries),
    // flash the confirmation, then close.
    // Plain text always (MIME text part); HTML only when formatting exists,
    // so unformatted mail stays a simple text/plain message.
    const formatted = bodyEl?.querySelector("b,strong,i,em,u,s,strike,ul,ol,li,a");
    onSend({
      accountId: fromId,
      to: toChips.map((c) => c.email),
      cc: ccChips.map((c) => c.email),
      bcc: bccChips.map((c) => c.email),
      subject,
      body: bodyEl?.innerText ?? body.replace(/<br\s*\/?>/g, "\n").replace(/<[^>]+>/g, ""),
      bodyHtml: formatted ? bodyEl!.innerHTML : undefined,
      attachments: attachments.length ? attachments : undefined,
    });
    sent = true;
    sentFlashTimer = setTimeout(() => {
      sent = false;
      onClose();
    }, 700);
  }
</script>

<svelte:document onmousedown={onDocMousedown} />

{#snippet toolbar()}
  {#each FORMAT_OPTIONS as [d, label, cmd] (label)}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <span onmousedown={(e) => e.preventDefault()}>
      <IconButton size="sm" {label} onclick={() => exec(cmd)}>
        <Icon {d} size={14} />
      </IconButton>
    </span>
  {/each}
{/snippet}

{#if sent}
  <div class="sent">Message sent</div>
{:else}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="drop-target"
    class:dragging
    ondragenter={onDragEnter}
    ondragover={(ev) => ev.dataTransfer?.types.includes("Files") && ev.preventDefault()}
    ondragleave={onDragLeave}
    ondrop={onDrop}
  >
  {#if dragging}
    <div class="drop-overlay">Drop to attach</div>
  {/if}
  {#if accounts.length > 1}
    <div class="field-row">
      <span class="field-label">From</span>
      <div class="from-picker" bind:this={fromRoot}>
        <button class="from-chip" class:open={fromOpen} onclick={() => (fromOpen = !fromOpen)}>
          {#if fromAccount}
            <span class="from-dot" style:background="var(--tag-{fromAccount.tag}-fg)"></span>
          {/if}
          <span class="from-email">{fromAccount?.email ?? fromId}</span>
          <svg class="from-chevron" width="10" height="10" viewBox="0 0 24 24" fill="none">
            <path d="M6 9l6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </button>
        {#if fromOpen}
          <div class="from-menu">
            {#each accounts as a (a.id)}
              <button
                class="from-option"
                class:selected={a.id === fromId}
                onclick={() => {
                  switchFrom(a.id);
                  fromOpen = false;
                }}
              >
                <span class="from-dot" style:background="var(--tag-{a.tag}-fg)"></span>
                <span class="from-opt-body">
                  <span class="from-opt-name">{a.label}</span>
                  <span class="from-opt-email">{a.email}</span>
                </span>
                {#if a.id === fromId}
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                    <path d="M20 6L9 17l-5-5" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" />
                  </svg>
                {/if}
              </button>
            {/each}
          </div>
        {/if}
      </div>
    </div>
  {/if}
  <div class="field-row">
    <span class="field-label">To</span>
    <RecipientField bind:chips={toChips} />
    {#if !showCc}
      <button class="cc-toggle" onclick={() => (showCc = true)}>Cc/Bcc</button>
    {/if}
  </div>
  {#if showCc}
    <div class="field-row">
      <span class="field-label">Cc</span>
      <RecipientField bind:chips={ccChips} />
    </div>
    <div class="field-row">
      <span class="field-label">Bcc</span>
      <RecipientField bind:chips={bccChips} />
    </div>
  {/if}
  <div class="field-row bordered">
    <span class="field-label">Subject</span>
    <input class="subject" bind:value={subject} />
  </div>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="editor"
    contenteditable="true"
    bind:this={bodyEl}
    use:initBody
    oninput={() => (body = bodyEl?.innerHTML ?? "")}
    onpaste={onPaste}
    onmouseup={onBodySelect}
    onkeydown={onBodyKeydown}
    onkeyup={onBodySelect}
    data-placeholder="Write your message..."
  ></div>
  {#if selPos}
    <div bind:this={selRoot} class="sel-toolbar" style:top="{selPos.top}px" style:left="{selPos.left}px">
      {@render toolbar()}
    </div>
  {/if}
  {#if linkPos}
    <div bind:this={linkRoot} class="link-popup" style:top="{linkPos.top}px" style:left="{linkPos.left}px">
      <!-- svelte-ignore a11y_autofocus -->
      <input
        class="link-input"
        autofocus
        placeholder="Paste or type a URL…"
        bind:value={linkUrl}
        onkeydown={(ev) => {
          if (ev.key === "Enter") {
            ev.preventDefault();
            applyLink();
          } else if (ev.key === "Escape") {
            ev.preventDefault();
            ev.stopPropagation();
            closeLink();
          }
        }}
      />
      <button class="link-apply" disabled={!linkUrl.trim()} onclick={applyLink}>Link</button>
    </div>
  {/if}
  {#if attachments.length > 0}
    <div class="chips">
      {#each attachments as a, i (a.filename + i)}
        <span class="chip" title="{a.filename} ({fmtSize(a.size)})">
          <Icon d="M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9" size={14} />
          <span class="chip-name">{a.filename}</span>
          <span class="chip-size">{fmtSize(a.size)}</span>
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
    <AiEditPopover getTarget={aiGetTarget} onApply={aiApply} />
    <input
      bind:this={fileInput}
      type="file"
      multiple
      hidden
      onchange={(ev) => {
        addFiles(ev.currentTarget.files);
        ev.currentTarget.value = "";
      }}
    />
    <IconButton size="sm" label="Attach file" onclick={() => fileInput?.click()}>
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
  .drop-target {
    position: relative;
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
  }
  .drop-overlay {
    position: absolute;
    inset: 0;
    z-index: 50;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--surface-card);
    border: 2px dashed var(--text-tertiary);
    border-radius: var(--radius-lg);
    font-family: var(--font-body);
    font-size: 14px;
    font-weight: 600;
    color: var(--text-secondary);
    pointer-events: none;
  }
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
    font-size: 13px;
    font-weight: 600;
    color: var(--text-tertiary);
  }
  .from-picker {
    position: relative;
    display: flex;
    align-items: center;
  }
  .from-chip {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    border: 1px solid transparent;
    background: none;
    cursor: pointer;
    padding: 4px 10px;
    margin-left: -10px;
    border-radius: var(--radius-pill);
    font-family: var(--font-body);
    font-size: 14px;
    color: var(--text-primary);
    transition:
      background 100ms,
      border-color 100ms;
  }
  .from-chip:hover,
  .from-chip.open {
    background: var(--surface-hover);
    border-color: transparent;
  }
  .from-chevron {
    color: var(--text-tertiary);
  }
  .from-menu {
    position: absolute;
    top: calc(100% + 6px);
    left: -10px;
    z-index: 40;
    min-width: 260px;
    background: var(--surface-card);
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-lg);
    padding: 4px;
  }
  .from-option {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    border: none;
    background: none;
    cursor: pointer;
    padding: 8px 10px;
    border-radius: var(--radius-sm);
    text-align: left;
    color: var(--text-primary);
  }
  .from-option:hover {
    background: var(--surface-hover);
  }
  .from-opt-body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
  }
  .from-opt-name {
    font-family: var(--font-body);
    font-size: 13.5px;
    font-weight: 600;
  }
  .from-opt-email {
    font-family: var(--font-body);
    font-size: 12.5px;
    color: var(--text-tertiary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .from-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
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
    font-weight: 700;
    color: var(--text-primary);
  }
  .editor {
    border: none;
    outline: none;
    padding: 24px 0 13px;
    font-family: var(--font-body);
    font-size: 14px;
    line-height: 1.55;
    color: var(--text-primary);
    width: 100%;
    background: none;
    box-sizing: border-box;
    flex: 1;
    min-height: 260px;
    overflow-wrap: break-word;
  }
  .editor:empty::before {
    content: attr(data-placeholder);
    color: var(--text-tertiary);
    pointer-events: none;
  }
  .editor :global(a) {
    color: var(--text-primary);
    text-decoration: underline;
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
    border-radius: var(--radius-pill);
    font-family: var(--font-body);
    font-size: 12.5px;
    color: var(--text-secondary);
    max-width: 260px;
  }
  .chip-name {
    font-weight: 600;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }
  .chip-size {
    color: var(--text-tertiary);
    font-size: 11.5px;
    flex-shrink: 0;
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
    background: var(--surface-inverse);
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
  .link-popup {
    position: fixed;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px;
    background: var(--surface-card);
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-md);
    z-index: 30;
  }
  .link-input {
    border: none;
    outline: none;
    background: var(--bg-canvas);
    border-radius: var(--radius-md);
    padding: 7px 10px;
    width: 260px;
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-primary);
  }
  .link-apply {
    border: none;
    background: var(--surface-inverse);
    color: var(--text-inverse);
    cursor: pointer;
    padding: 7px 14px;
    border-radius: var(--radius-pill);
    font-family: var(--font-body);
    font-size: 12.5px;
    font-weight: 700;
  }
  .link-apply:disabled {
    opacity: 0.4;
    cursor: default;
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
