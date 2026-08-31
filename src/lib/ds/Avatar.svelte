<script lang="ts">
  // Image avatar with initials fallback. Gravatar is the only sender-photo
  // source that needs no server and no extra OAuth scope (Gmail's API exposes
  // no sender photos).
  // ponytail: leaks a SHA-256 of the sender address to gravatar.com per row;
  // gate behind the remote-image privacy setting when M3 lands.
  let {
    email,
    name,
    size = 26,
    bg = "var(--surface-sunken)",
    fg = "var(--text-secondary)",
    fontWeight = 600,
  }: {
    email?: string;
    name: string;
    size?: number;
    bg?: string;
    fg?: string;
    fontWeight?: number;
  } = $props();

  let failed = $state(false);
  let url: string | null = $state(null);

  const initials = $derived(
    name
      .split(/[@.\s]/)
      .filter(Boolean)
      .slice(0, 2)
      .map((w) => w[0].toUpperCase())
      .join(""),
  );

  $effect(() => {
    failed = false;
    url = null;
    const addr = email?.trim().toLowerCase();
    if (!addr) return;
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(addr)).then((buf) => {
      const hex = Array.from(new Uint8Array(buf))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
      url = `https://gravatar.com/avatar/${hex}?d=404&s=${size * 2}`;
    });
  });
</script>

{#if url && !failed}
  <img
    src={url}
    alt={name}
    width={size}
    height={size}
    class="avatar-img"
    onerror={() => (failed = true)}
  />
{:else}
  <span
    class="avatar-initials"
    style:width="{size}px"
    style:height="{size}px"
    style:background={bg}
    style:color={fg}
    style:font-size="{Math.max(10, Math.round(size * 0.4))}px"
    style:font-weight={fontWeight}>{initials}</span
  >
{/if}

<style>
  .avatar-img {
    border-radius: 50%;
    object-fit: cover;
    flex-shrink: 0;
    display: block;
  }
  .avatar-initials {
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: var(--font-body);
    flex-shrink: 0;
  }
</style>
