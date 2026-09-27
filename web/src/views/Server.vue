<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { api } from '../api/client'
import UiCard from '../components/UiCard.vue'
import UiButton from '../components/UiButton.vue'

const auth = useAuthStore()
const router = useRouter()
const doctorOut = ref('')
const busy = ref(false)

async function runDoctor() {
  busy.value = true
  doctorOut.value = ''
  try {
    const res = await api.rpc<{ healthy: boolean }>('doctor')
    doctorOut.value = res.healthy ? 'Всё хорошо' : 'Есть проблемы — смотрите вывод doctor на сервере'
  } catch {
    doctorOut.value = 'doctor не удался'
  } finally {
    busy.value = false
  }
}

async function logout() {
  await auth.logout()
  router.replace('/login')
}
</script>

<template>
  <main class="mx-auto max-w-2xl space-y-3 px-4 pb-24 pt-6">
    <h1 class="px-1 text-[28px] font-bold tracking-tight">Сервер</h1>
    <UiCard>
      <p class="text-[16px] font-semibold">{{ auth.username }}</p>
      <p class="mb-3 text-[13px] text-[var(--color-ios-secondary)]">Администратор панели</p>
      <UiButton variant="danger" @click="logout">Выйти</UiButton>
    </UiCard>
    <UiCard>
      <p class="mb-1 text-[16px] font-semibold">Диагностика</p>
      <p class="mb-3 text-[13px] text-[var(--color-ios-secondary)]">vpnsetup doctor на хосте</p>
      <UiButton variant="plain" :disabled="busy" @click="runDoctor">
        {{ busy ? 'Проверка…' : 'Проверить' }}
      </UiButton>
      <p v-if="doctorOut" class="mt-2 text-[14px]">{{ doctorOut }}</p>
    </UiCard>
  </main>
</template>
