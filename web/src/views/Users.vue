<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { api, type PanelSummary, type UnifiedUser } from '../api/client'
import UiCard from '../components/UiCard.vue'
import EmptyState from '../components/EmptyState.vue'

const panels = ref<PanelSummary[]>([])
const current = ref('')
const users = ref<UnifiedUser[]>([])
const loading = ref(false)
const error = ref('')

function fmtBytes(n: number) {
  if (!n) return '0 Б'
  const u = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ']
  const i = Math.min(u.length - 1, Math.floor(Math.log(n) / Math.log(1024)))
  return `${(n / 1024 ** i).toFixed(1)} ${u[i]}`
}

function statusText(s: UnifiedUser['status']) {
  return { active: 'активен', disabled: 'выкл', limited: 'лимит', expired: 'истёк' }[s]
}

async function load() {
  if (!current.value) return
  loading.value = true
  error.value = ''
  try {
    users.value = (await api.users(current.value)).users
  } catch {
    error.value = 'Не удалось загрузить юзеров — проверьте настройку панели на сервере'
    users.value = []
  } finally {
    loading.value = false
  }
}

watch(current, load)

onMounted(async () => {
  try {
    panels.value = (await api.panels()).panels.filter((p) => p.installed && p.manageable)
    current.value = panels.value[0]?.id ?? ''
  } catch {
    error.value = 'Не удалось загрузить панели'
  }
})
</script>

<template>
  <main class="mx-auto max-w-2xl space-y-3 px-4 pb-24 pt-6">
    <h1 class="px-1 text-[28px] font-bold tracking-tight">Юзеры</h1>
    <div v-if="panels.length > 1" class="flex gap-2 overflow-x-auto px-1">
      <button
        v-for="p in panels"
        :key="p.id"
        class="shrink-0 rounded-full px-4 py-1.5 text-[14px] font-medium"
        :class="current === p.id ? 'bg-[var(--color-ios-accent)] text-white' : 'bg-[var(--color-ios-card)] dark:bg-[#1c1c1e]'"
        @click="current = p.id"
      >
        {{ p.name }}
      </button>
    </div>
    <p v-if="loading" class="px-1 text-[var(--color-ios-secondary)]">Загрузка…</p>
    <p v-else-if="error" class="px-1 text-[var(--color-ios-red)]">{{ error }}</p>
    <template v-else>
      <UiCard v-for="u in users" :key="u.id">
        <div class="flex items-center justify-between">
          <p class="text-[16px] font-semibold">{{ u.username }}</p>
          <span class="text-[13px] text-[var(--color-ios-secondary)]">{{ statusText(u.status) }}</span>
        </div>
        <p class="mt-1 text-[13px] text-[var(--color-ios-secondary)]">
          {{ fmtBytes(u.usedBytes) }}{{ u.limitBytes ? ` / ${fmtBytes(u.limitBytes)}` : ' · без лимита' }}
        </p>
      </UiCard>
      <EmptyState v-if="!users.length" text="Нет юзеров" />
    </template>
  </main>
</template>
