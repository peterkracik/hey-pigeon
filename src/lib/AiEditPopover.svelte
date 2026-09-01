<script lang="ts">
  import IconButton from "./ds/IconButton.svelte";
  import Icon from "./ds/Icon.svelte";
  import { toast } from "./toast.svelte";
  import * as ipc from "./ipc";

  /** Predefined instructions shown as one-click badges. */
  const AI_PRESETS: { label: string; instruction: string }[] = [
    { label: "Fix grammar", instruction: "Fix grammar and spelling mistakes. Keep the meaning and tone unchanged." },
    { label: "Reformulate", instruction: "Rewrite this more clearly, keeping the same meaning and roughly the same length." },
    { label: "Shorten", instruction: "Make this more concise without losing the key points." },
    { label: "Expand", instruction: "Expand this with a bit more detail and context." },
    { label: "More formal", instruction: "Rewrite this in a more formal, professional tone." },
    { label: "More casual", instruction: "Rewrite this in a more casual, friendly tone." },
  ];
  /** Shown once a result exists, to refine it further — applied to the
   *  current draft, not the original text, so badges chain (e.g. Warmer
   *  then More concise). Tone-focused, since the wording is already close
   *  by this point and tone is what's left to dial in. */
  const AI_TONE_PRESETS: { label: string; instruction: string }[] = [
    { label: "Warmer", instruction: "Make the tone warmer and friendlier, without changing the meaning." },
    { label: "More formal", instruction: "Make the tone more formal and professional, without changing the meaning." },
    { label: "More casual", instruction: "Make the tone more casual and relaxed, without changing the meaning." },
    { label: "More confident", instruction: "Make the tone more confident and direct, without changing the meaning." },
    { label: "Softer", instruction: "Soften the tone — more polite and less blunt — without changing the meaning." },
    { label: "More concise", instruction: "Make it more concise without losing the key points." },
  ];
  const AI_D = "M12 3l1.8 5.4L19 10l-5.2 1.6L12 17l-1.8-5.4L5 10l5.2-1.6z M19 15l.8 2.4L22 18l-2.2.6-.8 2.4-.8-2.4L16 18l2.2-.6z";

  let {
    getTarget,
    onApply,
    history,
  }: {
    /** Called once when the popover opens — returns the text to operate on
     *  (current selection, if any) and whether it came from a selection
     *  (only used for the hint text). The host is responsible for saving
     *  whatever it needs (a Range, textarea indices…) to apply the result
     *  later — this component never touches the host's DOM directly,
     *  contenteditable vs. textarea differ too much for that. */
    getTarget: () => { text: string; hasSelection: boolean };
    /** Commit the reviewed result — called only after the user accepts it. */
    onApply: (result: string) => void;
    /** Plain-text conversation transcript, when replying inside a thread —
     *  lets the model answer a question raised earlier instead of only
     *  reshaping the target text. */
    history?: string;
  } = $props();

  let open = $state(false);
  let root: HTMLDivElement | undefined = $state();
  let instruction = $state("");
  let running = $state(false);
  let hasSelection = $state(false);
  let targetText = "";
  // Pending output, held for review — onApply only runs once the user
  // explicitly accepts it. null = no result yet (showing badges/input).
  let result: string | null = $state(null);

  function toggle() {
    if (open) {
      close();
      return;
    }
    const t = getTarget();
    targetText = t.text;
    hasSelection = t.hasSelection;
    instruction = "";
    result = null;
    open = true;
  }

  function close() {
    open = false;
    instruction = "";
    result = null;
  }

  /** Back to badges/input — the target text and instruction stay put so a
   *  tweak-and-retry is one edit away, not a fresh start. */
  function discard() {
    result = null;
  }

  function apply() {
    if (result === null) return;
    onApply(result);
    close();
  }

  /** `base` is what the instruction applies to — the original target text
   *  for the first run, or the current `result` for a refinement, so tone
   *  badges chain onto each other instead of restarting from scratch. */
  async function run(text: string, base: string) {
    if (!ipc.isTauri) {
      toast("info", "Connect an AI provider", "Add an API key in Settings to use AI actions");
      return;
    }
    const trimmed = text.trim();
    if (!trimmed || running) return;
    if (!base.trim()) {
      toast("info", "Nothing to edit", "Write something first");
      return;
    }
    running = true;
    try {
      result = await ipc.aiEditText("openai", trimmed, base, history);
    } catch (e) {
      toast("danger", "AI action failed", String(e));
    } finally {
      running = false;
    }
  }

  function onDocMousedown(ev: MouseEvent) {
    if (open && root && !root.contains(ev.target as Node)) close();
  }
</script>

<svelte:document onmousedown={onDocMousedown} />

<div bind:this={root} class="ai-root">
  <IconButton size="sm" label="AI" onclick={toggle}>
    <Icon d={AI_D} size={14} />
  </IconButton>
  {#if open}
    <div class="ai-popup">
      {#if result !== null}
        {@const r = result}
        <div class="ai-hint">Review before it replaces {hasSelection ? "the selected text" : "the email"}</div>
        <div class="ai-preview">{r}</div>
        <div class="ai-hint">Adjust the tone?</div>
        <div class="ai-badges">
          {#each AI_TONE_PRESETS as p (p.label)}
            <button class="ai-badge" disabled={running} onclick={() => run(p.instruction, r)}>
              {p.label}
            </button>
          {/each}
        </div>
        <div class="ai-preview-actions">
          <button class="ai-badge" disabled={running} onclick={discard}>Discard</button>
          <button class="ai-go" disabled={running} onclick={apply}>
            {hasSelection ? "Replace selection" : "Replace email"}
          </button>
        </div>
      {:else}
        <div class="ai-hint">{hasSelection ? "Do something with the selected text" : "Do something with this email"}</div>
        <div class="ai-badges">
          {#each AI_PRESETS as p (p.label)}
            <button class="ai-badge" disabled={running} onclick={() => run(p.instruction, targetText)}>
              {p.label}
            </button>
          {/each}
        </div>
        <div class="ai-input-row">
          <!-- svelte-ignore a11y_autofocus -->
          <input
            class="ai-input"
            autofocus
            placeholder="Or tell it what to do…"
            disabled={running}
            bind:value={instruction}
            onkeydown={(ev) => {
              if (ev.key === "Enter") {
                ev.preventDefault();
                run(instruction, targetText);
              } else if (ev.key === "Escape") {
                ev.preventDefault();
                ev.stopPropagation();
                close();
              }
            }}
          />
          <button class="ai-go" disabled={!instruction.trim() || running} onclick={() => run(instruction, targetText)}>
            {running ? "Thinking…" : "Go"}
          </button>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .ai-root {
    position: relative;
  }
  .ai-popup {
    position: absolute;
    bottom: calc(100% + 8px);
    left: 0;
    display: flex;
    flex-direction: column;
    gap: 10px;
    width: 320px;
    padding: 12px;
    background: var(--surface-card);
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-md);
    z-index: 30;
    box-sizing: border-box;
  }
  .ai-hint {
    font-family: var(--font-body);
    font-size: 12px;
    color: var(--text-tertiary);
  }
  .ai-preview {
    max-height: 220px;
    overflow-y: auto;
    padding: 8px 10px;
    background: var(--bg-canvas);
    border-radius: var(--radius-md);
    font-family: var(--font-body);
    font-size: 13px;
    line-height: 1.5;
    color: var(--text-primary);
    white-space: pre-wrap;
  }
  .ai-preview-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }
  .ai-badges {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .ai-badge {
    border: 1px solid var(--border-subtle);
    background: var(--bg-canvas);
    color: var(--text-secondary);
    cursor: pointer;
    padding: 5px 10px;
    border-radius: var(--radius-pill);
    font-family: var(--font-body);
    font-size: 12px;
    font-weight: 600;
  }
  .ai-badge:hover:not(:disabled) {
    background: var(--surface-hover);
    color: var(--text-primary);
  }
  .ai-badge:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .ai-input-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .ai-input {
    flex: 1;
    min-width: 0;
    border: none;
    outline: none;
    background: var(--bg-canvas);
    border-radius: var(--radius-md);
    padding: 7px 10px;
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-primary);
  }
  .ai-go {
    flex-shrink: 0;
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
  .ai-go:disabled {
    opacity: 0.4;
    cursor: default;
  }
</style>
