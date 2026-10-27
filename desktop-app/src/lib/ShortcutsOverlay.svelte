<script lang="ts">
  /** Keyboard cheat sheet ('?' / palette "Keyboard shortcuts"). Pure view:
   *  the owner handles Escape/'?' to close, same as the other overlays. Keep
   *  this list in step with App.svelte's onKey and CommandPalette's COMMANDS. */
  let {
    open,
    onClose,
  }: {
    open: boolean;
    onClose: () => void;
  } = $props();

  interface Shortcut {
    keys: string[];
    label: string;
  }
  interface Group {
    title: string;
    items: Shortcut[];
  }

  const GROUPS: Group[] = [
    {
      title: "Navigate",
      items: [
        { keys: ["J", "↓"], label: "Next thread" },
        { keys: ["K", "↑"], label: "Previous thread" },
        { keys: ["↵"], label: "Open thread" },
        { keys: ["Esc"], label: "Back · close · clear selection" },
        { keys: ["/"], label: "Quick filter (search inside a thread)" },
        { keys: ["⌘", "K"], label: "Command palette" },
        { keys: ["G", "I"], label: "Go to Inbox" },
        { keys: ["G", "U"], label: "Go to All Inboxes" },
        { keys: ["?"], label: "This cheat sheet" },
      ],
    },
    {
      title: "Triage",
      items: [
        { keys: ["E"], label: "Mark done" },
        { keys: ["#"], label: "Delete" },
        { keys: ["U"], label: "Mark unread / read" },
        { keys: ["S"], label: "Pin" },
        { keys: ["N"], label: "Need reply" },
        { keys: ["H"], label: "Remind me (or “only if no reply”)" },
        { keys: ["L"], label: "Add label" },
        { keys: ["V"], label: "Move to folder" },
        { keys: ["X"], label: "Select row" },
      ],
    },
    {
      title: "Write",
      items: [
        { keys: ["C"], label: "Compose new message" },
        { keys: ["R"], label: "Reply" },
        { keys: ["F"], label: "Forward" },
        { keys: ["⌘", "B"], label: "Bold (while writing)" },
        { keys: ["⌘", "I"], label: "Italic (while writing)" },
        { keys: ["⌘", "U"], label: "Underline (while writing)" },
      ],
    },
  ];
</script>

{#if open}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="backdrop" onclick={onClose}>
    <div class="panel" role="dialog" tabindex="-1" aria-label="Keyboard shortcuts" onclick={(ev) => ev.stopPropagation()}>
      <div class="head">
        <span class="title">Keyboard shortcuts</span>
        <span class="esc">ESC</span>
      </div>
      <div class="groups">
        {#each GROUPS as g (g.title)}
          <section class="group">
            <h3>{g.title}</h3>
            {#each g.items as s (s.label)}
              <div class="row">
                <span class="label">{s.label}</span>
                <span class="keys">
                  {#each s.keys as k, i (i)}
                    {#if i > 0 && s.keys.length === 2 && (k === "↓" || k === "↑")}<span class="or">or</span>{/if}
                    <span class="key">{k}</span>
                  {/each}
                </span>
              </div>
            {/each}
          </section>
        {/each}
      </div>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(17, 19, 24, 0.32);
    backdrop-filter: blur(6px);
    z-index: 90;
    display: flex;
    justify-content: center;
    align-items: center;
    padding: 40px;
  }
  .panel {
    width: 760px;
    max-width: 100%;
    max-height: 88vh;
    overflow-y: auto;
    background: var(--surface-inverse);
    border-radius: var(--radius-2xl);
    box-shadow: var(--shadow-lg);
    box-sizing: border-box;
  }
  .head {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-4) var(--space-5);
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  }
  .title {
    flex: 1;
    font-family: var(--font-display);
    font-weight: 800;
    letter-spacing: -0.01em;
    font-size: 16px;
    color: var(--text-inverse);
  }
  .esc {
    font-family: var(--font-mono);
    font-size: 11px;
    color: rgba(255, 255, 255, 0.35);
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: var(--radius-sm);
    padding: var(--space-1) var(--space-2);
  }
  .groups {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: var(--space-5);
    padding: var(--space-4) var(--space-5) var(--space-5);
  }
  @media (max-width: 720px) {
    .groups {
      grid-template-columns: 1fr;
    }
  }
  h3 {
    margin: 0 0 var(--space-2);
    padding: 0 var(--space-2);
    font-family: var(--font-body);
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.4);
  }
  .row {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: 6px var(--space-2);
    border-radius: var(--radius-md);
  }
  .row:hover {
    background: rgba(255, 255, 255, 0.06);
  }
  .label {
    flex: 1;
    min-width: 0;
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-inverse);
  }
  .keys {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
  }
  .key {
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: rgba(255, 255, 255, 0.7);
    background: rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-sm);
    padding: 3px var(--space-2);
    min-width: 18px;
    text-align: center;
  }
  .or {
    font-family: var(--font-body);
    font-size: 10.5px;
    color: rgba(255, 255, 255, 0.35);
  }
</style>
