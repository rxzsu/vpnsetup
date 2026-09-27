<script setup lang="ts">
defineProps<{ label: string; modelValue: string; type?: string; autocomplete?: string }>()
defineEmits<{ (e: 'update:modelValue', v: string): void }>()
</script>

<template>
  <label class="block">
    <span class="mb-1 block text-[13px] text-[var(--color-ios-secondary)]">{{ label }}</span>
    <input
      :value="modelValue"
      :type="type ?? 'text'"
      :autocomplete="autocomplete"
      class="w-full rounded-xl border border-[var(--color-ios-separator)] bg-[var(--color-ios-bg)] px-3 py-2.5 text-[16px] outline-none focus:border-[var(--color-ios-accent)] dark:bg-[#2c2c2e]"
      @input="($event.target as HTMLInputElement) && $emit('update:modelValue', ($event.target as HTMLInputElement).value)"
    />
  </label>
</template>
