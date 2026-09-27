<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { AnimatePresence, motion } from 'motion-v'
import {
  api,
  type ConfigProfile,
  type NodeCapabilities,
  type PanelSummary,
  type UnifiedNode,
} from '../api/client'
import UiCard from '../components/UiCard.vue'
import UiButton from '../components/UiButton.vue'
import UiField from '../components/UiField.vue'
import UiModal from '../components/UiModal.vue'
import EmptyState from '../components/EmptyState.vue'

const panels = ref<PanelSummary[]>([])
const current = ref('')
const nodes = ref<UnifiedNode[]>([])
const caps = ref<NodeCapabilities>({ canAdd: false, canDelete: false, canRestart: false, canToggle: false })
const loading = ref(false)
const error = ref('')
const notice = ref('')
const busyId = ref('')
const openId = ref('')

const showCreate = ref(false)
const profiles = ref<ConfigProfile[]>([])
const form = ref({ name: '', address: '', port: '62050', apiPort: '62051', profileUuid: '', inboundUuids: [] as string[] })
const formBusy = ref(false)
const formError = ref('')
const confirmDelete = ref<UnifiedNode | null>(null)

function isRemnawave() {
  return current.value === 'remnawave'
}

function flash(msg: string) {
  notice.value = msg
  setTimeout(() => (notice.value = ''), 3000)
}

function selectedProfile(): ConfigProfile | undefined {
  return profiles.value.find((p) => p.uuid === form.value.profileUuid)
}

async function load() {
  if (!current.value) return
  loading.value = true
  error.value = ''
  try {
    const res = await api.nodes(current.value)
    nodes.value = res.nodes
    caps.value = res.capabilities
  } catch {
    error.value = 'Не удалось загрузить ноды'
    nodes.value = []
  } finally {
    loading.value = false
  }
}

async function openCreate() {
  form.value = { name: '', address: '', port: '62050', apiPort: '62051', profileUuid: '', inboundUuids: [] }
  formError.value = ''
  profiles.value = []
  if (isRemnawave()) {
    try {
      const res = await api.nodeOptions(current.value)
      profiles.value = res.profiles
      form.value.profileUuid = profiles.value[0]?.uuid ?? ''
      syncInboundDefaults()
    } catch (e) {
      formError.value = (e as Error).message
    }
  }
  showCreate.value = true
}

function syncInboundDefaults() {
  form.value.inboundUuids = (selectedProfile()?.inbounds ?? []).map((i) => i.uuid)
}

async function submitCreate() {
  if (!form.value.name.trim() || !form.value.address.trim()) {
    formError.value = 'Введите имя и адрес'
    return
  }
  if (isRemnawave() && !form.value.profileUuid) {
    formError.value = 'Выберите config profile'
    return
  }
  formBusy.value = true
  formError.value = ''
  try {
    const { node } = await api.createNode(current.value, {
      name: form.value.name.trim(),
      address: form.value.address.trim(),
      port: Number(form.value.port) || undefined,
      apiPort: Number(form.value.apiPort) || undefined,
      profileUuid: form.value.profileUuid || undefined,
      inboundUuids: form.value.inboundUuids.length ? form.value.inboundUuids : undefined,
    })
    nodes.value = [...nodes.value, node]
    showCreate.value = false
    flash('Нода добавлена')
  } catch (e) {
    formError.value = (e as Error).message
  } finally {
    formBusy.value = false
  }
}

async function toggle(n: UnifiedNode) {
  const enabled = n.status === 'disabled' || n.status === 'offline'
  busyId.value = n.id
  try {
    const { node } = await api.setNodeEnabled(current.value, n.id, enabled)
    nodes.value = nodes.value.map((x) => (x.id === n.id ? node : x))
  } catch (e) {
    flash((e as Error).message)
  } finally {
    busyId.value = ''
  }
}

async function restart(n: UnifiedNode) {
  busyId.value = n.id
  try {
    await api.restartNode(current.value, n.id)
    flash('Перезапуск запущен')
  } catch (e) {
    flash((e as Error).message)
  } finally {
    busyId.value = ''
  }
}

async function remove() {
  const n = confirmDelete.value
  if (!n) return
  busyId.value = n.id
  try {
    await api.deleteNode(current.value, n.id)
    nodes.value = nodes.value.filter((x) => x.id !== n.id)
    flash('Нода удалена')
  } catch (e) {
    flash((e as Error).message)
  } finally {
    busyId.value = ''
    confirmDelete.value = null
  }
}

watch(current, () => {
  openId.value = ''
  load()
})

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
    <div class="flex items-center justify-between px-1">
      <h1 class="text-[28px] font-bold tracking-tight">Ноды</h1>
      <button
        v-if="caps.canAdd"
        class="flex h-8 w-8 items-center justify-center rounded-full bg-[var(--color-ios-accent)] text-[20px] leading-none text-white active:scale-95"
        @click="openCreate"
      >
        +
      </button>
    </div>
    <p v-if="notice" class="px-1 text-[14px] text-[var(--color-ios-green)]">{{ notice }}</p>
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
      <UiCard v-for="n in nodes" :key="n.id">
        <button class="flex w-full items-center justify-between text-left" @click="openId = openId === n.id ? '' : n.id">
          <div>
            <p class="text-[16px] font-semibold">{{ n.name }}</p>
            <p class="mt-0.5 text-[13px] text-[var(--color-ios-secondary)]">{{ n.address }}</p>
          </div>
          <span class="text-[13px] text-[var(--color-ios-secondary)]">{{ n.status }}</span>
        </button>
        <AnimatePresence>
          <motion.div
            v-if="openId === n.id && (caps.canToggle || caps.canRestart || caps.canDelete)"
            :initial="{ height: 0, opacity: 0 }"
            :animate="{ height: 'auto', opacity: 1 }"
            :exit="{ height: 0, opacity: 0 }"
            class="overflow-hidden"
          >
            <div class="flex flex-wrap gap-2 pt-3">
              <UiButton v-if="caps.canToggle" variant="plain" :disabled="busyId === n.id" @click="toggle(n)">
                {{ n.status === 'disabled' || n.status === 'offline' ? 'Включить' : 'Выключить' }}
              </UiButton>
              <UiButton v-if="caps.canRestart" variant="plain" :disabled="busyId === n.id" @click="restart(n)">
                Перезапустить
              </UiButton>
              <UiButton v-if="caps.canDelete" variant="danger" :disabled="busyId === n.id" @click="confirmDelete = n">
                Удалить
              </UiButton>
            </div>
          </motion.div>
        </AnimatePresence>
      </UiCard>
      <EmptyState v-if="!nodes.length" text="Нет нод" />
    </template>

    <AnimatePresence>
      <UiModal v-if="showCreate" title="Новая нода" @close="showCreate = false">
        <div class="flex flex-col gap-3">
          <UiField v-model="form.name" label="Имя" autocomplete="off" />
          <UiField v-model="form.address" label="Адрес (IP или домен)" autocomplete="off" />
          <div class="grid grid-cols-2 gap-3">
            <UiField v-model="form.port" label="Порт" type="number" />
            <UiField v-if="!isRemnawave()" v-model="form.apiPort" label="API-порт" type="number" />
          </div>
          <template v-if="isRemnawave()">
            <label class="block">
              <span class="mb-1 block text-[13px] text-[var(--color-ios-secondary)]">Config profile</span>
              <select
                v-model="form.profileUuid"
                class="w-full rounded-xl border border-[var(--color-ios-separator)] bg-[var(--color-ios-bg)] px-3 py-2.5 text-[16px] outline-none dark:bg-[#2c2c2e]"
                @change="syncInboundDefaults"
              >
                <option v-for="p in profiles" :key="p.uuid" :value="p.uuid">{{ p.name }}</option>
              </select>
            </label>
            <template v-if="selectedProfile()">
              <p class="text-[13px] text-[var(--color-ios-secondary)]">Инбаунды</p>
              <div class="flex max-h-40 flex-col gap-1 overflow-y-auto">
                <label v-for="i in selectedProfile()!.inbounds" :key="i.uuid" class="flex items-center gap-2 text-[15px]">
                  <input v-model="form.inboundUuids" type="checkbox" :value="i.uuid" class="h-5 w-5 accent-[#007aff]" />
                  {{ i.tag }} <span class="text-[var(--color-ios-secondary)]">· {{ i.type }}</span>
                </label>
              </div>
            </template>
          </template>
          <p v-if="formError" class="text-[14px] text-[var(--color-ios-red)]">{{ formError }}</p>
          <UiButton :disabled="formBusy" @click="submitCreate">{{ formBusy ? 'Добавление…' : 'Добавить' }}</UiButton>
        </div>
      </UiModal>
    </AnimatePresence>

    <AnimatePresence>
      <UiModal v-if="confirmDelete" title="Удалить ноду?" @close="confirmDelete = null">
        <p class="mb-4 text-center text-[15px] text-[var(--color-ios-secondary)]">
          {{ confirmDelete.name }} будет отключена от панели
        </p>
        <div class="grid grid-cols-2 gap-2">
          <UiButton variant="plain" @click="confirmDelete = null">Отмена</UiButton>
          <UiButton variant="danger" @click="remove">Удалить</UiButton>
        </div>
      </UiModal>
    </AnimatePresence>
  </main>
</template>
