<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { motion } from 'motion-v'
import { api, type PanelSummary } from '../api/client'
import UiCard from '../components/UiCard.vue'
import EmptyState from '../components/EmptyState.vue'

const panels = ref<PanelSummary[]>([])
const loading = ref(true)
const error = ref('')

function statusColor(p: PanelSummary) {
  if (!p.installed) return 'text-[var(--color-ios-secondary)]'
  return 'text-[var(--color-ios-green)]'
}

onMounted(async () => {
  try {
    panels.value = (await api.panels()).panels
  } catch {
    error.value = 'Не удалось загрузить панели'
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <main class="mx-auto max-w-2xl space-y-3 px-4 pb-24 pt-6">
    <h1 class="px-1 text-[28px] font-bold tracking-tight">Обзор</h1>
    <p v-if="loading" class="px-1 text-[var(--color-ios-secondary)]">Загрузка…</p>
    <p v-else-if="error" class="px-1 text-[var(--color-ios-red)]">{{ error }}</p>
    <template v-else>
      <motion.div
        v-for="(p, i) in panels"
        :key="p.id"
        :initial="{ opacity: 0, y: 10 }"
        :animate="{ opacity: 1, y: 0 }"
        :transition="{ delay: i * 0.05 }"
      >
        <UiCard>
          <div class="flex items-center justify-between">
            <div>
              <p class="text-[17px] font-semibold">{{ p.name }}</p>
              <p class="text-[13px] text-[var(--color-ios-secondary)]">
                {{ p.domain ?? 'не установлена' }}{{ p.port ? ` · :${p.port}` : '' }}
              </p>
            </div>
            <span class="text-[13px] font-medium" :class="statusColor(p)">
              {{ p.installed ? '● работает' : '○ нет' }}
            </span>
          </div>
        </UiCard>
      </motion.div>
      <EmptyState v-if="!panels.length" text="Нет панелей" />
    </template>
  </main>
</template>
