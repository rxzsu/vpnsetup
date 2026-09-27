<script setup lang="ts">
defineProps<{ text: string }>()
</script>

<template>
  <p class="py-10 text-center text-[15px] text-[var(--color-ios-secondary)]">{{ text }}</p>
</template>
