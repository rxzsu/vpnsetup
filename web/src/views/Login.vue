<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { motion } from 'motion-v'
import { useAuthStore } from '../stores/auth'
import UiCard from '../components/UiCard.vue'
import UiButton from '../components/UiButton.vue'
import UiField from '../components/UiField.vue'

const auth = useAuthStore()
const router = useRouter()
const username = ref('')
const password = ref('')
const error = ref('')
const busy = ref(false)

async function submit() {
  error.value = ''
  busy.value = true
  try {
    await auth.login(username.value, password.value)
    router.replace('/')
  } catch {
    error.value = 'Неверный логин или пароль'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <main class="mx-auto flex min-h-dvh max-w-sm flex-col justify-center px-5">
    <motion.div :initial="{ opacity: 0, y: 12 }" :animate="{ opacity: 1, y: 0 }">
      <h1 class="mb-1 text-[28px] font-bold tracking-tight">VPN Panel</h1>
      <p class="mb-6 text-[15px] text-[var(--color-ios-secondary)]">Войдите, чтобы управлять сервером</p>
      <UiCard>
        <form class="flex flex-col gap-3" @submit.prevent="submit">
          <UiField v-model="username" label="Логин" autocomplete="username" />
          <UiField v-model="password" label="Пароль" type="password" autocomplete="current-password" />
          <p v-if="error" class="text-[14px] text-[var(--color-ios-red)]">{{ error }}</p>
          <UiButton type="submit" :disabled="busy || !username || !password">
            {{ busy ? 'Вход…' : 'Войти' }}
          </UiButton>
        </form>
      </UiCard>
    </motion.div>
  </main>
</template>
