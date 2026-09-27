<script setup lang="ts">
import { motion } from 'motion-v'

defineProps<{ title: string }>()
defineEmits<{ (e: 'close'): void }>()
</script>

<template>
  <motion.div
    class="fixed inset-0 z-20 flex items-end justify-center bg-black/30 sm:items-center"
    :initial="{ opacity: 0 }"
    :animate="{ opacity: 1 }"
    :exit="{ opacity: 0 }"
    @click.self="$emit('close')"
  >
    <motion.div
      class="w-full max-w-md rounded-t-3xl bg-[var(--color-ios-card)] p-5 pb-[env(safe-area-inset-bottom)] sm:rounded-3xl dark:bg-[#1c1c1e]"
      :initial="{ y: 40, opacity: 0 }"
      :animate="{ y: 0, opacity: 1 }"
      :exit="{ y: 40, opacity: 0 }"
    >
      <p class="mb-4 text-center text-[17px] font-semibold">{{ title }}</p>
      <slot />
    </motion.div>
  </motion.div>
</template>
