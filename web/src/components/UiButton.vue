<script setup lang="ts">
withDefaults(
  defineProps<{ variant?: 'primary' | 'plain' | 'danger'; type?: 'button' | 'submit'; disabled?: boolean }>(),
  { variant: 'primary', type: 'button', disabled: false },
)
</script>

<template>
  <button
    :type="type"
    :disabled="disabled"
    class="rounded-xl px-4 py-2.5 text-[15px] font-semibold transition active:scale-[0.98] disabled:opacity-40"
    :class="
      variant === 'primary'
        ? 'bg-[var(--color-ios-accent)] text-white'
        : variant === 'danger'
          ? 'bg-[var(--color-ios-red)]/10 text-[var(--color-ios-red)]'
          : 'text-[var(--color-ios-accent)]'
    "
  >
    <slot />
  </button>
</template>
