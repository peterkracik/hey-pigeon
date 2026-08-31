<script lang="ts">
  let {
    open,
    onClose,
  }: {
    open: boolean;
    onClose: () => void;
  } = $props();

  const contacts = [
    { n: "Priya Nair", e: "priya@heypigeon.app" },
    { n: "Sam Okoye", e: "sam@heypigeon.app" },
    { n: "Ana Torres", e: "ana@heypigeon.app" },
  ];
</script>

{#if open}
  <div class="overlay">
    <div class="search-row">
      <!-- svelte-ignore a11y_autofocus -->
      <input autofocus placeholder="Search" />
      <button class="close" aria-label="Close search" onclick={onClose}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
          <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
        </svg>
      </button>
    </div>
    {#each contacts as c (c.e)}
      <div class="contact">
        <span class="name">{c.n}</span>
        <span class="email">{c.e}</span>
      </div>
    {/each}
  </div>
{/if}

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: var(--surface-card);
    z-index: 60;
    padding: 24px 32px;
  }
  .search-row {
    display: flex;
    align-items: center;
    gap: 12px;
    border-bottom: 1px solid var(--border-subtle);
    padding-bottom: 14px;
    margin-bottom: 20px;
  }
  input {
    flex: 1;
    border: none;
    outline: none;
    background: none;
    font-family: var(--font-body);
    font-size: 20px;
    color: var(--text-primary);
  }
  .close {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
  }
  .contact {
    display: flex;
    gap: 16px;
    padding: 9px 0;
    font-family: var(--font-body);
    font-size: 14px;
  }
  .name {
    color: var(--text-primary);
    font-weight: 500;
  }
  .email {
    color: var(--text-tertiary);
  }
</style>
