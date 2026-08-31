<script lang="ts">
  let {
    checked = false,
    label,
    name,
    disabled = false,
    onchange,
  }: {
    checked?: boolean;
    label?: string;
    name?: string;
    disabled?: boolean;
    onchange?: () => void;
  } = $props();
</script>

<label class="radio" class:disabled>
  <span class="ring" class:checked>
    {#if checked}<span class="dot"></span>{/if}
  </span>
  <input type="radio" {name} {checked} {disabled} onchange={() => onchange?.()} />
  {#if label}{label}{/if}
</label>

<style>
  .radio {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    cursor: pointer;
    font-family: var(--font-body);
    font-size: var(--text-body);
    color: var(--text-primary);
  }
  .radio.disabled {
    cursor: not-allowed;
    opacity: 0.5;
  }
  .ring {
    width: 18px;
    height: 18px;
    box-sizing: border-box;
    border-radius: 50%;
    border: 1px solid var(--border-default);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--surface-card);
  }
  .ring.checked {
    border-color: var(--accent-primary);
  }
  .dot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: var(--accent-primary);
  }
  input {
    display: none;
  }
</style>
