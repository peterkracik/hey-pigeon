<script lang="ts">
  let {
    checked = $bindable(false),
    disabled = false,
    label,
    onchange,
  }: {
    checked?: boolean;
    disabled?: boolean;
    label?: string;
    onchange?: (checked: boolean) => void;
  } = $props();
</script>

<label class="switch" class:disabled>
  <span class="track" class:on={checked}>
    <span class="knob" class:on={checked}></span>
  </span>
  <input
    type="checkbox"
    bind:checked
    {disabled}
    onchange={() => onchange?.(checked)}
  />
  {#if label}{label}{/if}
</label>

<style>
  .switch {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    cursor: pointer;
    font-family: var(--font-body);
    font-size: var(--text-body);
    color: var(--text-primary);
  }
  .switch.disabled {
    cursor: not-allowed;
    opacity: 0.5;
  }
  .track {
    width: 36px;
    height: 22px;
    border-radius: var(--radius-pill);
    padding: 2px;
    box-sizing: border-box;
    background: var(--navy-300);
    display: inline-flex;
    align-items: center;
    transition: background var(--duration-base) var(--ease-standard);
  }
  .track.on {
    background: var(--accent-highlight);
  }
  .knob {
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: var(--white);
    box-shadow: var(--shadow-xs);
    transform: translateX(0);
    transition: transform var(--duration-base) var(--ease-standard);
  }
  .knob.on {
    transform: translateX(14px);
  }
  input {
    display: none;
  }
</style>
