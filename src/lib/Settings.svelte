<script lang="ts">
  import Switch from "./ds/Switch.svelte";
  import Select from "./ds/Select.svelte";
  import Radio from "./ds/Radio.svelte";
  import Button from "./ds/Button.svelte";
  import { EMAIL_ACTIONS, initials, type Account } from "./data";

  let {
    accounts,
    hoverActions,
    onHoverActionsChange,
    pinListEnabled,
    onPinListChange,
  }: {
    accounts: Account[];
    hoverActions: string[];
    onHoverActionsChange: (next: string[]) => void;
    pinListEnabled: boolean;
    onPinListChange: (v: boolean) => void;
  } = $props();

  let signature = $state(true);
  let signatureText = $state("Peter\nHey Pigeon");
  let dragKey: string | null = $state(null);
  let readReceipts = $state(false);
  let desktopNotif = $state(true);
  let notifSound = $state(true);
  let notifPreview = $state("sender-subject");
  let density = $state("comfortable");
  let theme = $state("system");
  let swipeRight = $state("done");
  let autoAdvance = $state("newer");
  let blockTracking = $state(true);

  function reorderOrAdd(targetIndex: number) {
    if (!dragKey) return;
    let next = hoverActions.filter((k) => k !== dragKey);
    const insertAt = Math.min(targetIndex, next.length);
    next.splice(insertAt, 0, dragKey);
    if (next.length > 3) next = next.slice(0, 3);
    onHoverActionsChange(next);
    dragKey = null;
  }
</script>

{#snippet settingRow(title: string, description: string)}
  <div class="setting-row">
    <div class="setting-text">
      <div class="setting-title">{title}</div>
      {#if description}
        <div class="setting-desc">{description}</div>
      {/if}
    </div>
  </div>
{/snippet}

<div class="settings">
  <section>
    <div class="group-head">
      <h2>Accounts</h2>
      <p>Connected mailboxes shown in the sidebar.</p>
    </div>
    <div class="group-body">
      {#each accounts as a (a.id)}
        <div class="account-row">
          <span class="account-avatar" style:background="var(--tag-{a.tag}-bg)" style:color="var(--tag-{a.tag}-fg)"
            >{initials(a.label)}</span
          >
          <div class="account-text">
            <div class="setting-title">{a.label}</div>
            <div class="account-email">{a.email}</div>
          </div>
          <Button variant="ghost" size="sm">Remove</Button>
        </div>
      {/each}
      <div class="add-account">
        <Button variant="secondary" size="sm">Add account</Button>
      </div>
    </div>
  </section>

  <section>
    <div class="group-head"><h2>Notifications</h2></div>
    <div class="group-body">
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">Desktop notifications</div>
          <div class="setting-desc">Show a system notification for new mail while Hey Pigeon is open.</div>
        </div>
        <div class="setting-control"><Switch bind:checked={desktopNotif} /></div>
      </div>
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">Notification sound</div>
          <div class="setting-desc">Play a sound when new mail arrives.</div>
        </div>
        <div class="setting-control"><Switch bind:checked={notifSound} /></div>
      </div>
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">Preview content</div>
          <div class="setting-desc">What to show in a new mail notification.</div>
        </div>
        <div class="setting-control">
          <Select
            bind:value={notifPreview}
            options={[
              { value: "sender-subject", label: "Sender & subject" },
              { value: "sender-only", label: "Sender only" },
              { value: "none", label: "Nothing" },
            ]}
          />
        </div>
      </div>
    </div>
  </section>

  <section>
    <div class="group-head"><h2>Appearance</h2></div>
    <div class="group-body">
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">Theme</div>
          <div class="setting-desc">Match your system, or set Hey Pigeon independently.</div>
        </div>
        <div class="setting-control theme-radios">
          {#each [["system", "System"], ["light", "Light"], ["dark", "Dark"]] as [v, l] (v)}
            <Radio name="theme" label={l} checked={theme === v} onchange={() => (theme = v)} />
          {/each}
        </div>
      </div>
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">List density</div>
          <div class="setting-desc">How much space each message row takes up.</div>
        </div>
        <div class="setting-control">
          <Select
            bind:value={density}
            options={[
              { value: "comfortable", label: "Comfortable" },
              { value: "compact", label: "Compact" },
            ]}
          />
        </div>
      </div>
    </div>
  </section>

  <section>
    <div class="group-head">
      <h2>Inbox</h2>
      <p>Control how messages are grouped and which actions appear on hover.</p>
    </div>
    <div class="group-body">
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">Pinned list</div>
          <div class="setting-desc">Group pinned messages at the top of your inbox, above the rest.</div>
        </div>
        <div class="setting-control">
          <Switch checked={pinListEnabled} onchange={(v) => onPinListChange(v)} />
        </div>
      </div>
      {@render settingRow("Hover actions", "Drag up to 3 actions into the box to show them when you hover a message.")}
      <div class="hover-actions">
        <div>
          <div class="drag-label">Selected (drag to reorder)</div>
          <div
            class="drop-zone"
            role="list"
            ondragover={(e) => e.preventDefault()}
            ondrop={(e) => {
              e.preventDefault();
              reorderOrAdd(hoverActions.length);
            }}
          >
            {#each hoverActions as k, i (k)}
              {@const a = EMAIL_ACTIONS.find((x) => x.key === k)}
              {#if a}
                <span
                  class="action-chip selected"
                  role="listitem"
                  draggable="true"
                  ondragstart={() => (dragKey = k)}
                  ondragend={() => (dragKey = null)}
                  ondragover={(e) => {
                    e.preventDefault();
                    e.stopPropagation();
                  }}
                  ondrop={(e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    reorderOrAdd(i);
                  }}
                >
                  {a.label}
                  <button class="chip-x" aria-label="Remove {a.label}" onclick={() => onHoverActionsChange(hoverActions.filter((x) => x !== k))}>
                    <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
                      <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
                    </svg>
                  </button>
                </span>
              {/if}
            {/each}
            {#if hoverActions.length === 0}
              <span class="drop-hint">Drop actions here</span>
            {/if}
          </div>
        </div>
        <div>
          <div class="drag-label">Available</div>
          <div
            class="available-zone"
            role="list"
            ondragover={(e) => e.preventDefault()}
            ondrop={(e) => {
              e.preventDefault();
              if (dragKey) onHoverActionsChange(hoverActions.filter((k) => k !== dragKey));
              dragKey = null;
            }}
          >
            {#each EMAIL_ACTIONS.filter((a) => !hoverActions.includes(a.key)) as a (a.key)}
              <span
                class="action-chip"
                role="listitem"
                draggable="true"
                ondragstart={() => (dragKey = a.key)}
                ondragend={() => (dragKey = null)}
              >
                {a.label}
              </span>
            {/each}
          </div>
        </div>
      </div>
    </div>
  </section>

  <section>
    <div class="group-head"><h2>Reading &amp; replying</h2></div>
    <div class="group-body">
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">Include signature</div>
          <div class="setting-desc">Add your signature to new messages automatically.</div>
        </div>
        <div class="setting-control"><Switch bind:checked={signature} /></div>
      </div>
      {#if signature}
        <div class="signature-wrap">
          <textarea bind:value={signatureText} rows="4"></textarea>
        </div>
      {/if}
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">Send read receipts</div>
          <div class="setting-desc">Let senders know when you've opened their message.</div>
        </div>
        <div class="setting-control"><Switch bind:checked={readReceipts} /></div>
      </div>
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">Swipe right on a message</div>
          <div class="setting-desc">Choose what a right swipe does in the inbox list.</div>
        </div>
        <div class="setting-control">
          <Select
            bind:value={swipeRight}
            options={[
              { value: "done", label: "Mark done" },
              { value: "delete", label: "Delete" },
              { value: "snooze", label: "Snooze" },
            ]}
          />
        </div>
      </div>
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">After archiving or deleting</div>
          <div class="setting-desc">Which message to open next.</div>
        </div>
        <div class="setting-control">
          <Select
            bind:value={autoAdvance}
            options={[
              { value: "newer", label: "Newer message" },
              { value: "older", label: "Older message" },
              { value: "list", label: "Back to list" },
            ]}
          />
        </div>
      </div>
    </div>
  </section>

  <section>
    <div class="group-head"><h2>Privacy</h2></div>
    <div class="group-body">
      <div class="setting-row">
        <div class="setting-text">
          <div class="setting-title">Block external images by default</div>
          <div class="setting-desc">
            Stop remote images from loading until you choose to show them, to limit sender tracking.
          </div>
        </div>
        <div class="setting-control"><Switch bind:checked={blockTracking} /></div>
      </div>
    </div>
  </section>
</div>

<style>
  .settings {
    width: 100%;
    padding-bottom: 60px;
  }
  section {
    margin-bottom: 40px;
  }
  .group-head {
    margin-bottom: 4px;
  }
  .group-head h2 {
    margin: 0;
    font-family: var(--font-mono);
    font-weight: 600;
    font-size: 12px;
    color: var(--accent-highlight);
  }
  .group-head p {
    margin: 4px 0 0;
    font-family: var(--font-body);
    font-size: 13.5px;
    color: var(--text-tertiary);
  }
  .group-body {
    margin-top: 12px;
  }
  .setting-row {
    display: flex;
    align-items: center;
    gap: 24px;
    padding: 16px 0;
    border-bottom: 1px solid var(--navy-50);
  }
  .setting-text {
    flex: 1;
    min-width: 0;
  }
  .setting-title {
    font-family: var(--font-body);
    font-size: 14.5px;
    font-weight: 600;
    color: var(--text-primary);
  }
  .setting-desc {
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-tertiary);
    margin-top: 3px;
    line-height: 1.5;
  }
  .setting-control {
    flex-shrink: 0;
  }
  .theme-radios {
    display: flex;
    gap: 18px;
  }
  .account-row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 0;
    border-bottom: 1px solid var(--navy-50);
  }
  .account-avatar {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: var(--font-body);
    font-size: 13px;
    font-weight: 700;
    flex-shrink: 0;
  }
  .account-text {
    flex: 1;
    min-width: 0;
  }
  .account-email {
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-tertiary);
  }
  .add-account {
    padding-top: 14px;
  }
  .hover-actions {
    display: flex;
    flex-direction: column;
    gap: 14px;
    padding: 0 0 16px;
  }
  .drag-label {
    font-family: var(--font-body);
    font-size: 12px;
    color: var(--text-tertiary);
    margin-bottom: 6px;
  }
  .drop-zone {
    display: flex;
    gap: 8px;
    min-height: 40px;
    align-items: center;
    padding: 8px;
    border: 1px dashed var(--border-default);
    border-radius: var(--radius-md);
  }
  .available-zone {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    min-height: 34px;
    padding: 8px;
  }
  .action-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    background: var(--surface-card);
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-pill);
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-secondary);
    cursor: grab;
  }
  .action-chip.selected {
    padding: 6px 6px 6px 12px;
    background: var(--surface-sunken);
    border: none;
    font-weight: 600;
    color: var(--text-primary);
  }
  .chip-x {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    display: flex;
    padding: 4px;
  }
  .drop-hint {
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-tertiary);
  }
  .signature-wrap {
    padding: 0 0 16px;
  }
  .signature-wrap textarea {
    width: 100%;
    box-sizing: border-box;
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-md);
    padding: 12px;
    resize: vertical;
    font-family: var(--font-body);
    font-size: 13.5px;
    color: var(--text-primary);
    outline: none;
    background: none;
  }
</style>
