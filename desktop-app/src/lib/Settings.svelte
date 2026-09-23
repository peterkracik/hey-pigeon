<script lang="ts">
  import Switch from "./ds/Switch.svelte";
  import Button from "./ds/Button.svelte";
  import Avatar from "./ds/Avatar.svelte";
  import { ACCOUNT_COLOR_TAGS, EMAIL_ACTIONS, type Account } from "./data";
  import * as ipc from "./ipc";

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

  // ------------------------------------------------------------ AI provider
  // Self-contained (like SearchOverlay): nothing outside Settings needs AI
  // status yet, so it talks to ipc directly instead of round-tripping
  // through App.svelte props. Only "openai" exists today.
  const AI_PROVIDER = "openai";

  let aiStatus = $state<ipc.AiStatus | null>(null);
  let aiModelOptions: ipc.AiModel[] = $state([]);
  let aiKeyInput = $state("");
  let aiSaving = $state(false);
  let aiError: string | null = $state(null);
  let confirmingRemoveAi = $state(false);

  // Runs once when Settings mounts (the modal creates/destroys this
  // component per open, so this is effectively "fetch on open").
  if (ipc.isTauri) {
    ipc
      .aiModels(AI_PROVIDER)
      .then((m) => (aiModelOptions = m))
      .catch(() => {});
    ipc
      .aiStatus()
      .then((s) => (aiStatus = s))
      .catch(() => {});
  }

  // ------------------------------------------------------- device sync
  // Reminders sync between the user's devices through the account's own
  // hidden Drive folder (DESIGN.md "Cross-device sync"). Read-only here:
  // the only fix for a failure is re-connecting the account or enabling
  // the Drive API, both outside this panel.
  let syncStatus: Record<string, ipc.SyncStatus> = $state({});
  // `now` ticks with the poll so "3 min ago" stays honest while the panel
  // is open (the sync loop runs every 30s; re-read on the same cadence).
  let now = $state(Date.now());
  $effect(() => {
    if (!ipc.isTauri) return;
    const load = () => {
      now = Date.now();
      ipc
        .syncStatus()
        .then((s) => (syncStatus = s))
        .catch(() => {});
    };
    load();
    const timer = setInterval(load, 30_000);
    return () => clearInterval(timer);
  });

  function syncLine(accountId: string): { text: string; warn: boolean } {
    const s = syncStatus[accountId];
    if (!s) return { text: "Waiting for first sync", warn: false };
    switch (s.state) {
      case "pending":
        return { text: "Syncing…", warn: false };
      case "ok":
        return { text: "On", warn: false };
      case "auth_expired":
        return { text: "Sign in again to sync reminders", warn: true };
      case "unavailable":
      case "error":
        return { text: s.detail ?? "Sync failed", warn: true };
    }
  }

  function lastSyncLine(accountId: string): string {
    const s = syncStatus[accountId];
    if (!s) return "";
    return `Last sync: ${relativeTime(s.last_sync_at)}`;
  }

  function relativeTime(ms: number | null): string {
    if (ms == null) return "never";
    const secs = Math.max(0, Math.round((now - ms) / 1000));
    if (secs < 60) return "just now";
    const mins = Math.round(secs / 60);
    if (mins < 60) return `${mins} min ago`;
    const hours = Math.round(mins / 60);
    if (hours < 24) return `${hours} h ago`;
    return `${Math.round(hours / 24)} d ago`;
  }

  const aiConnected = $derived(aiStatus?.configured ?? false);
  const aiModelLabel = $derived(
    aiModelOptions.find((m) => m.id === aiStatus?.model)?.label ?? aiStatus?.model ?? "—",
  );

  async function connectAi() {
    const key = aiKeyInput.trim();
    if (!ipc.isTauri || !key) return;
    aiSaving = true;
    aiError = null;
    try {
      await ipc.setAiKey(AI_PROVIDER, key);
      // Default to the first (cheapest) model on first connect.
      const defaultModel = aiModelOptions[0]?.id;
      if (defaultModel) await ipc.setAiModel(AI_PROVIDER, defaultModel);
      aiStatus = await ipc.aiStatus();
      aiKeyInput = "";
    } catch (e) {
      aiError = String(e);
    } finally {
      aiSaving = false;
    }
  }

  async function disconnectAi() {
    if (!ipc.isTauri) return;
    confirmingRemoveAi = false;
    try {
      await ipc.removeAiKey(AI_PROVIDER);
      aiStatus = await ipc.aiStatus();
    } catch (e) {
      aiError = String(e);
    }
  }

  async function selectAiModel(model: string) {
    if (!ipc.isTauri || !aiStatus) return;
    const prev = aiStatus.model;
    aiStatus = { ...aiStatus, model }; // optimistic — it's a plain local pref
    try {
      await ipc.setAiModel(AI_PROVIDER, model);
    } catch (e) {
      aiError = String(e);
      aiStatus = { ...aiStatus, model: prev };
    }
  }

  // --------------------------------------------------------- AI triage (Jev)
  // Runs automatically in the background (unlike the AI section above,
  // which only ever sends content on an explicit action) — the copy below
  // must say so plainly.
  let triageStatus = $state<ipc.TriageStatus | null>(null);
  let triageLabels: ipc.BackendTriageLabel[] = $state([]);
  let jevKeyInput = $state("");
  let jevSaving = $state(false);
  let jevError: string | null = $state(null);
  let confirmingRemoveJev = $state(false);
  let newLabelInput = $state("");
  let labelError: string | null = $state(null);

  if (ipc.isTauri) {
    ipc
      .autolabelStatus()
      .then((s) => (triageStatus = s))
      .catch(() => {});
    ipc
      .listTriageLabels()
      .then((l) => (triageLabels = l))
      .catch(() => {});
  }

  const triageConfigured = $derived(triageStatus?.configured ?? false);
  const triageEnabled = $derived(triageStatus?.enabled ?? false);

  async function connectJev() {
    const key = jevKeyInput.trim();
    if (!ipc.isTauri || !key) return;
    jevSaving = true;
    jevError = null;
    try {
      await ipc.setJevKey(key);
      triageStatus = await ipc.autolabelStatus();
      jevKeyInput = "";
    } catch (e) {
      jevError = String(e);
    } finally {
      jevSaving = false;
    }
  }

  async function disconnectJev() {
    if (!ipc.isTauri) return;
    confirmingRemoveJev = false;
    try {
      await ipc.removeJevKey();
      triageStatus = await ipc.autolabelStatus();
    } catch (e) {
      jevError = String(e);
    }
  }

  async function toggleAutolabel(v: boolean) {
    if (!ipc.isTauri || !triageStatus) return;
    const prev = triageStatus.enabled;
    triageStatus = { ...triageStatus, enabled: v }; // optimistic
    try {
      await ipc.setAutolabelEnabled(v);
    } catch (e) {
      jevError = String(e);
      triageStatus = { ...triageStatus, enabled: prev };
    }
  }

  async function addTriageLabel() {
    const name = newLabelInput.trim();
    if (!ipc.isTauri || !name) return;
    labelError = null;
    try {
      const label = await ipc.createTriageLabel(name);
      triageLabels = [...triageLabels, label].sort((a, b) => a.name.localeCompare(b.name));
      newLabelInput = "";
    } catch (e) {
      labelError = String(e);
    }
  }

  async function removeTriageLabel(id: string) {
    if (!ipc.isTauri) return;
    labelError = null;
    try {
      await ipc.deleteTriageLabel(id);
      triageLabels = triageLabels.filter((l) => l.id !== id);
    } catch (e) {
      labelError = String(e);
    }
  }

  // Doesn't clear anything itself — just marks every thread stale so the
  // ~30s poll gradually reclassifies the whole mailbox (bounded per tick).
  let reanalyzeQueued = $state(false);
  async function reanalyzeAll() {
    if (!ipc.isTauri) return;
    labelError = null;
    try {
      await ipc.reanalyzeAllTriage();
      reanalyzeQueued = true;
    } catch (e) {
      labelError = String(e);
    }
  }

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
            {#if ipc.isTauri}
              {@const sync = syncLine(a.id)}
              <div class="sub-row">
                <span class="sub-label">Sync</span>
                <span class="sub-static" title="Reminders sync between your devices via this account's hidden Google Drive app folder.">
                  <span class:warn={sync.warn}>{sync.text}</span>
                  {#if lastSyncLine(a.id)}
                    <span class="sub-muted"> · {lastSyncLine(a.id)}</span>
                  {/if}
                </span>
              </div>
            {/if}
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
      <h2>AI</h2>
      <p>Bring your own API key. Email content is sent to the provider only when you press an AI action — never in the background.</p>
    </div>
    <div class="group-body">
      <div class="account-block">
        <div class="account-row">
          <div class="ai-mark">AI</div>
          <div class="account-text">
            <div class="setting-title">ChatGPT (OpenAI)</div>
            <div class="account-email">{aiConnected ? `Connected · ${aiModelLabel}` : "Not connected"}</div>
          </div>
          {#if aiConnected}
            {#if confirmingRemoveAi}
              <Button variant="danger" size="sm" onclick={disconnectAi}>Really remove?</Button>
            {:else}
              <Button variant="ghost" size="sm" onclick={() => (confirmingRemoveAi = true)}>Remove</Button>
            {/if}
          {/if}
        </div>
        {#if aiConnected}
          <div class="account-subsettings">
            <div class="sub-row">
              <span class="sub-label">Model</span>
              <select
                class="sub-input"
                value={aiStatus?.model ?? aiModelOptions[0]?.id}
                onchange={(ev) => selectAiModel(ev.currentTarget.value)}
              >
                {#each aiModelOptions as m (m.id)}
                  <option value={m.id}>{m.label}</option>
                {/each}
              </select>
            </div>
          </div>
        {:else}
          <div class="ai-connect-row">
            <input
              class="sub-input ai-key-input"
              type="password"
              autocomplete="off"
              placeholder="sk-…"
              bind:value={aiKeyInput}
              onkeydown={(ev) => {
                if (ev.key === "Enter") connectAi();
              }}
            />
            <Button variant="secondary" size="sm" disabled={!aiKeyInput.trim() || aiSaving} onclick={connectAi}>
              {aiSaving ? "Verifying…" : "Connect"}
            </Button>
          </div>
          {#if aiError}
            <div class="ai-error">{aiError}</div>
          {/if}
        {/if}
      </div>
    </div>
  </section>

  <section>
    <div class="group-head">
      <h2>Triage</h2>
      <p>
        Jev sorts new mail into your own labels below and flags a priority automatically, in the background — subject and
        snippet (never the full message) are sent to Jev to do this.
      </p>
    </div>
    <div class="group-body">
      <div class="account-block">
        <div class="account-row">
          <div class="ai-mark">TS</div>
          <div class="account-text">
            <div class="setting-title">Jev</div>
            <div class="account-email">{triageConfigured ? "Connected" : "Not connected"}</div>
          </div>
          {#if triageConfigured}
            {#if confirmingRemoveJev}
              <Button variant="danger" size="sm" onclick={disconnectJev}>Really remove?</Button>
            {:else}
              <Button variant="ghost" size="sm" onclick={() => (confirmingRemoveJev = true)}>Remove</Button>
            {/if}
          {/if}
        </div>
        {#if triageConfigured}
          <div class="account-subsettings">
            <div class="sub-row">
              <span class="sub-label">Auto-triage</span>
              <Switch checked={triageEnabled} onchange={toggleAutolabel} />
            </div>
            <div class="sub-row">
              <span class="sub-label">Reanalyze</span>
              <div class="reanalyze-control">
                <Button
                  variant="secondary"
                  size="sm"
                  onclick={() => {
                    reanalyzeQueued = false;
                    reanalyzeAll();
                  }}
                >
                  Reanalyze all emails
                </Button>
                {#if reanalyzeQueued}
                  <span class="sub-muted">Queued — processes gradually in the background.</span>
                {/if}
              </div>
            </div>
            {#if triageStatus?.last_error}
              <div class="sub-row">
                <span class="sub-static warn">Last run failed: {triageStatus.last_error}</span>
              </div>
            {/if}
          </div>
        {:else}
          <div class="ai-connect-row">
            <input
              class="sub-input ai-key-input"
              type="password"
              autocomplete="off"
              placeholder="API key"
              bind:value={jevKeyInput}
              onkeydown={(ev) => {
                if (ev.key === "Enter") connectJev();
              }}
            />
            <Button variant="secondary" size="sm" disabled={!jevKeyInput.trim() || jevSaving} onclick={connectJev}>
              {jevSaving ? "Verifying…" : "Connect"}
            </Button>
          </div>
          {#if jevError}
            <div class="ai-error">{jevError}</div>
          {/if}
        {/if}
      </div>

      <div class="triage-labels">
        <div class="drag-label">Labels</div>
        <div class="available-zone">
          {#each triageLabels as l (l.id)}
            <span class="action-chip selected">
              {l.name}
              <button class="chip-x" aria-label="Remove {l.name}" onclick={() => removeTriageLabel(l.id)}>
                <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
                  <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
                </svg>
              </button>
            </span>
          {/each}
          {#if triageLabels.length === 0}
            <span class="drop-hint">No labels yet</span>
          {/if}
        </div>
        <div class="ai-connect-row">
          <input
            class="sub-input"
            placeholder="New label name"
            bind:value={newLabelInput}
            onkeydown={(ev) => {
              if (ev.key === "Enter") addTriageLabel();
            }}
          />
          <Button variant="secondary" size="sm" disabled={!newLabelInput.trim()} onclick={addTriageLabel}>Add</Button>
        </div>
        {#if labelError}
          <div class="ai-error">{labelError}</div>
        {/if}
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
    padding: 8px 0 40px;
  }
  section {
    margin-bottom: 36px;
  }
  .group-head {
    margin-bottom: 4px;
  }
  .group-head h2 {
    margin: 0;
    font-family: var(--font-display);
    font-weight: 800;
    letter-spacing: -0.01em;
    font-size: 16px;
    color: var(--text-primary);
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
  .ai-mark {
    width: 32px;
    height: 32px;
    flex-shrink: 0;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--surface-inverse);
    color: var(--text-inverse);
    font-family: var(--font-display);
    font-weight: 700;
    font-size: 11px;
    letter-spacing: 0.02em;
  }
  .ai-connect-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 4px 0 0 44px;
  }
  .ai-key-input {
    flex: 0 1 320px;
    font-family: var(--font-mono);
  }
  .ai-error {
    padding: 6px 0 0 44px;
    font-family: var(--font-body);
    font-size: 12.5px;
    color: var(--tag-coral-fg);
  }
  .add-account {
    padding-top: 14px;
  }
  .triage-labels {
    margin-top: 16px;
  }
  .reanalyze-control {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
  }
  .reanalyze-control :global(.btn) {
    flex-shrink: 0;
    white-space: nowrap;
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
    border-radius: var(--radius-lg);
    background: var(--bg-canvas);
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
    background: var(--surface-inverse);
    border: none;
    font-weight: 600;
    color: var(--text-inverse);
  }
  .chip-x {
    border: none;
    background: none;
    cursor: pointer;
    color: inherit;
    opacity: 0.6;
    display: flex;
    padding: 4px;
  }
  .chip-x:hover {
    opacity: 1;
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
  .sub-static {
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-secondary);
  }
  .sub-static .warn {
    color: var(--text-danger, #b3261e);
  }
  .sub-muted {
    color: var(--text-tertiary);
  }
  .sub-input {
    flex: 0 1 260px;
    border: 1px solid transparent;
    background: var(--bg-canvas);
    border-radius: var(--radius-md);
    outline: none;
    font-family: var(--font-body);
    font-size: 13.5px;
    color: var(--text-primary);
    padding: 7px 10px;
  }
  .sub-input:focus {
    border-color: var(--text-primary);
    background: var(--surface-card);
  }
  .sub-signature {
    flex: 0 1 420px;
    box-sizing: border-box;
    border: 1px solid transparent;
    border-radius: var(--radius-lg);
    padding: 10px 12px;
    resize: vertical;
    font-family: var(--font-body);
    font-size: 13px;
    color: var(--text-primary);
    outline: none;
    background: var(--bg-canvas);
  }
  .sub-signature:focus {
    border-color: var(--text-primary);
    background: var(--surface-card);
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
