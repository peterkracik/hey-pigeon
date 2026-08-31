<script lang="ts">
  import Switch from "./ds/Switch.svelte";
  import Button from "./ds/Button.svelte";
  import Avatar from "./ds/Avatar.svelte";
  import { ACCOUNT_COLOR_TAGS, EMAIL_ACTIONS, type Account } from "./data";

  let {
    accounts,
    hoverActions,
    onHoverActionsChange,
    pinListEnabled,
    onPinListChange,
    onAddAccount,
    onRemoveAccount,
    onUpdateAccount,
  }: {
    accounts: Account[];
    hoverActions: string[];
    onHoverActionsChange: (next: string[]) => void;
    pinListEnabled: boolean;
    onPinListChange: (v: boolean) => void;
    onAddAccount?: () => void;
    onRemoveAccount?: (id: string) => void;
    onUpdateAccount?: (id: string, fields: { displayName?: string; color?: string; signature?: string }) => void;
  } = $props();

  // confirm()/alert() are no-ops in the macOS webview — two-click confirm instead.
  let confirmingRemoveId: string | null = $state(null);

  let dragKey: string | null = $state(null);

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
        <div class="account-block">
          <div class="account-row">
            <Avatar src={a.avatarUrl} email={a.email} name={a.label} size={32} bg="var(--tag-{a.tag}-bg)" fg="var(--tag-{a.tag}-fg)" fontWeight={700} />
            <div class="account-text">
              <div class="setting-title">{a.label}</div>
              <div class="account-email">{a.email}</div>
            </div>
            {#if confirmingRemoveId === a.id}
              <Button
                variant="danger"
                size="sm"
                onclick={() => {
                  confirmingRemoveId = null;
                  onRemoveAccount?.(a.id);
                }}>Really remove?</Button
              >
            {:else}
              <Button variant="ghost" size="sm" onclick={() => (confirmingRemoveId = a.id)}>Remove</Button>
            {/if}
          </div>
          <div class="account-subsettings">
            <div class="sub-row">
              <span class="sub-label">Name</span>
              <input
                class="sub-input"
                value={a.label}
                onchange={(ev) => onUpdateAccount?.(a.id, { displayName: ev.currentTarget.value })}
              />
            </div>
            <div class="sub-row">
              <span class="sub-label">Color</span>
              <div class="color-picker" role="radiogroup" aria-label="Account color">
                {#each ACCOUNT_COLOR_TAGS as c (c)}
                  <button
                    class="color-dot"
                    class:selected={a.tag === c}
                    style:background="var(--tag-{c}-fg)"
                    title={c}
                    role="radio"
                    aria-checked={a.tag === c}
                    aria-label={c}
                    onclick={() => onUpdateAccount?.(a.id, { color: c })}
                  ></button>
                {/each}
              </div>
            </div>
            <div class="sub-row signature-row">
              <span class="sub-label">Signature</span>
              <textarea
                class="sub-signature"
                rows="3"
                placeholder="Appended to new messages from this account"
                value={a.signature ?? ""}
                onchange={(ev) => onUpdateAccount?.(a.id, { signature: ev.currentTarget.value })}
              ></textarea>
            </div>
          </div>
        </div>
      {/each}
      <div class="add-account">
        <Button variant="secondary" size="sm" onclick={() => onAddAccount?.()}>Add account</Button>
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

  <div class="copyright">© 2026 heypigeon.app · v1.0.0</div>
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
  .account-row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 0;
    border-bottom: 1px solid var(--navy-50);
  }
  .account-text {
    flex: 1;
    min-width: 0;
  }
  .color-picker {
    display: flex;
    gap: 8px;
    align-items: center;
    margin-right: 8px;
  }
  .color-dot {
    width: 16px;
    height: 16px;
    border-radius: 50%;
    border: 2px solid transparent;
    padding: 0;
    cursor: pointer;
    box-sizing: border-box;
    transition: transform var(--duration-fast) var(--ease-standard);
  }
  .color-dot:hover {
    transform: scale(1.15);
  }
  .color-dot.selected {
    border-color: var(--text-primary);
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
  .account-block {
    border-bottom: 1px solid var(--navy-50);
    padding-bottom: 14px;
  }
  .account-subsettings {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 4px 0 0 44px;
  }
  .sub-row {
    display: flex;
    align-items: center;
    gap: 16px;
  }
  .sub-row.signature-row {
    align-items: flex-start;
  }
  .sub-label {
    width: 70px;
    flex-shrink: 0;
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-tertiary);
  }
  .sub-input {
    flex: 0 1 260px;
    border: none;
    border-bottom: 1px solid var(--border-default);
    background: none;
    outline: none;
    font-family: var(--font-body);
    font-size: 13.5px;
    color: var(--text-primary);
    padding: 4px 2px;
  }
  .sub-input:focus {
    border-bottom-color: var(--text-primary);
  }
  .sub-signature {
    flex: 0 1 420px;
    box-sizing: border-box;
    border: 1px solid var(--border-subtle);
    border-radius: var(--radius-md);
    padding: 10px 12px;
    resize: vertical;
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-primary);
    outline: none;
    background: none;
  }
  .copyright {
    text-align: center;
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-tertiary);
    opacity: 0.6;
    padding-top: 8px;
  }
</style>
