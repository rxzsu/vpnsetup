<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { AnimatePresence, motion } from 'motion-v'
import {
  api,
  type CreateUserInput,
  type PanelSummary,
  type UnifiedNode,
  type UnifiedUser,
} from '../api/client'
import UiCard from '../components/UiCard.vue'
import UiButton from '../components/UiButton.vue'
import UiField from '../components/UiField.vue'
import UiModal from '../components/UiModal.vue'
import EmptyState from '../components/EmptyState.vue'

const panels = ref<PanelSummary[]>([])
const current = ref('')
const users = ref<UnifiedUser[]>([])
const inbounds = ref<UnifiedNode[]>([])
const loading = ref(false)
const error = ref('')
const notice = ref('')

const showCreate = ref(false)
const form = ref({ username: '', limitGb: '', days: '', inboundIds: [] as string[] })
const formBusy = ref(false)
const formError = ref('')

const confirmDelete = ref<UnifiedUser | null>(null)
const busyId = ref('')
const openId = ref('')

function fmtBytes(n: number) {
  if (!n) return '0 Б'
  const u = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ']
  const i = Math.min(u.length - 1, Math.floor(Math.log(n) / Math.log(1024)))
  return `${(n / 1024 ** i).toFixed(1)} ${u[i]}`
}

function statusText(s: UnifiedUser['status']) {
  return { active: 'активен', disabled: 'выкл', limited: 'лимит', expired: 'истёк' }[s]
}

function isXui() {
  return current.value === '3x-ui'
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

function flash(msg: string) {
  notice.value = msg
  setTimeout(() => (notice.value = ''), 3000)
}

async function openCreate() {
  form.value = { username: '', limitGb: '', days: '', inboundIds: [] }
  formError.value = ''
  inbounds.value = []
  if (isXui()) {
    try {
      inbounds.value = (await api.nodes(current.value)).nodes
      inbounds.value.forEach((n) => {
        if (n.status === 'enabled') form.value.inboundIds.push(n.id)
      })
    } catch {
      formError.value = 'Не удалось загрузить инбаунды'
    }
  }
  showCreate.value = true
}

async function submitCreate() {
  const name = form.value.username.trim()
  if (!name) {
    formError.value = 'Введите имя'
    return
  }
  if (isXui() && !form.value.inboundIds.length) {
    formError.value = 'Выберите хотя бы один инбаунд'
    return
  }
  formBusy.value = true
  formError.value = ''
  try {
    const input: CreateUserInput = { username: name }
    if (form.value.limitGb) input.limitBytes = Math.round(Number(form.value.limitGb) * 1024 ** 3)
    if (form.value.days) {
      input.expiresAt = new Date(Date.now() + Number(form.value.days) * 86400_000).toISOString()
    }
    if (isXui()) input.inboundIds = form.value.inboundIds.map(Number)
    const { user } = await api.createUser(current.value, input)
    users.value = [user, ...users.value]
    showCreate.value = false
    flash('Юзер создан')
  } catch (e) {
    formError.value = (e as Error).message
  } finally {
    formBusy.value = false
  }
}

async function toggle(u: UnifiedUser) {
  busyId.value = u.id
  try {
    const { user } = await api.updateUser(current.value, u.id, {
      status: u.status === 'active' ? 'disabled' : 'active',
    })
    users.value = users.value.map((x) => (x.id === u.id ? user : x))
  } catch (e) {
    flash((e as Error).message)
  } finally {
    busyId.value = ''
  }
}

async function reset(u: UnifiedUser) {
  busyId.value = u.id
  try {
    await api.resetUser(current.value, u.id)
    flash('Трафик сброшен')
    await load()
  } catch (e) {
    flash((e as Error).message)
  } finally {
    busyId.value = ''
  }
}

async function revoke(u: UnifiedUser) {
  busyId.value = u.id
  try {
    const { user } = await api.revokeUser(current.value, u.id)
    users.value = users.value.map((x) => (x.id === u.id ? user : x))
    flash(isXui() ? 'Ссылка подписки обновлена' : 'Подписка перевёрнута')
  } catch (e) {
    flash((e as Error).message)
  } finally {
    busyId.value = ''
  }
}

async function remove() {
  const u = confirmDelete.value
  if (!u) return
  busyId.value = u.id
  try {
    await api.deleteUser(current.value, u.id)
    users.value = users.value.filter((x) => x.id !== u.id)
    flash('Юзер удалён')
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
      <h1 class="text-[28px] font-bold tracking-tight">Юзеры</h1>
      <button
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
      <UiCard v-for="u in users" :key="u.id">
        <button class="flex w-full items-center justify-between text-left" @click="openId = openId === u.id ? '' : u.id">
          <div>
            <p class="text-[16px] font-semibold">{{ u.username }}</p>
            <p class="mt-0.5 text-[13px] text-[var(--color-ios-secondary)]">
              {{ fmtBytes(u.usedBytes) }}{{ u.limitBytes ? ` / ${fmtBytes(u.limitBytes)}` : ' · без лимита' }}
            </p>
          </div>
          <span class="text-[13px] text-[var(--color-ios-secondary)]">{{ statusText(u.status) }}</span>
        </button>
        <AnimatePresence>
          <motion.div
            v-if="openId === u.id"
            :initial="{ height: 0, opacity: 0 }"
            :animate="{ height: 'auto', opacity: 1 }"
            :exit="{ height: 0, opacity: 0 }"
            class="overflow-hidden"
          >
            <div class="flex flex-wrap gap-2 pt-3">
              <UiButton variant="plain" :disabled="busyId === u.id" @click="toggle(u)">
                {{ u.status === 'active' ? 'Выключить' : 'Включить' }}
              </UiButton>
              <UiButton variant="plain" :disabled="busyId === u.id" @click="reset(u)">Сбросить трафик</UiButton>
              <UiButton variant="plain" :disabled="busyId === u.id" @click="revoke(u)">
                {{ isXui() ? 'Обновить подписку' : 'Revoke' }}
              </UiButton>
              <UiButton variant="danger" :disabled="busyId === u.id" @click="confirmDelete = u">Удалить</UiButton>
            </div>
            <button
              v-if="u.subscriptionUrl"
              class="mt-2 truncate text-left text-[13px] text-[var(--color-ios-accent)]"
              @click="navigator.clipboard?.writeText(u.subscriptionUrl ?? '').then(() => flash('Ссылка скопирована'))"
            >
              {{ u.subscriptionUrl }}
            </button>
          </motion.div>
        </AnimatePresence>
      </UiCard>
      <EmptyState v-if="!users.length" text="Нет юзеров — нажмите +, чтобы создать" />
    </template>

    <AnimatePresence>
      <UiModal v-if="showCreate" title="Новый юзер" @close="showCreate = false">
        <div class="flex flex-col gap-3">
          <UiField v-model="form.username" label="Имя" autocomplete="off" />
          <div class="grid grid-cols-2 gap-3">
            <UiField v-model="form.limitGb" label="Лимит, ГБ (0 = ∞)" type="number" />
            <UiField v-model="form.days" label="Срок, дней (∞ = пусто)" type="number" />
          </div>
          <template v-if="isXui()">
            <p class="text-[13px] text-[var(--color-ios-secondary)]">Инбаунды</p>
            <div class="flex max-h-40 flex-col gap-1 overflow-y-auto">
              <label v-for="n in inbounds" :key="n.id" class="flex items-center gap-2 text-[15px]">
                <input v-model="form.inboundIds" type="checkbox" :value="n.id" class="h-5 w-5 accent-[#007aff]" />
                {{ n.name }}
              </label>
            </div>
          </template>
          <p v-if="formError" class="text-[14px] text-[var(--color-ios-red)]">{{ formError }}</p>
          <UiButton :disabled="formBusy" @click="submitCreate">{{ formBusy ? 'Создание…' : 'Создать' }}</UiButton>
        </div>
      </UiModal>
    </AnimatePresence>

    <AnimatePresence>
      <UiModal v-if="confirmDelete" title="Удалить юзера?" @close="confirmDelete = null">
        <p class="mb-4 text-center text-[15px] text-[var(--color-ios-secondary)]">
          {{ confirmDelete.username }} будет удалён безвозвратно
        </p>
        <div class="grid grid-cols-2 gap-2">
          <UiButton variant="plain" @click="confirmDelete = null">Отмена</UiButton>
          <UiButton variant="danger" @click="remove">Удалить</UiButton>
        </div>
      </UiModal>
    </AnimatePresence>
  </main>
</template>
