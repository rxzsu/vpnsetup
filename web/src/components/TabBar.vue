<script setup lang="ts">
import { useRoute } from 'vue-router'

const route = useRoute()
const tabs = [
  { to: '/', label: 'Обзор' },
  { to: '/users', label: 'Юзеры' },
  { to: '/nodes', label: 'Ноды' },
  { to: '/server', label: 'Сервер' },
]
</script>

<template>
  <nav
    class="fixed inset-x-0 bottom-0 z-10 border-t border-[var(--color-ios-separator)] bg-white/90 pb-[env(safe-area-inset-bottom)] backdrop-blur dark:bg-[#1c1c1e]/90"
  >
    <div class="mx-auto grid max-w-lg grid-cols-4">
      <RouterLink
        v-for="t in tabs"
        :key="t.to"
        :to="t.to"
        class="py-2.5 text-center text-[13px]"
        :class="route.path === t.to ? 'font-semibold text-[var(--color-ios-accent)]' : 'text-[var(--color-ios-secondary)]'"
      >
        {{ t.label }}
      </RouterLink>
    </div>
  </nav>
</template>
