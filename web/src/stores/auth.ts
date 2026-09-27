import { defineStore } from 'pinia'
import { ref } from 'vue'
import { api } from '../api/client'

export const useAuthStore = defineStore('auth', () => {
  const loggedIn = ref(false)
  const username = ref('')
  const checked = ref(false)

  async function me() {
    try {
      const res = await api.me()
      loggedIn.value = res.loggedIn
      username.value = res.username ?? ''
    } catch {
      loggedIn.value = false
    } finally {
      checked.value = true
    }
  }

  async function login(user: string, password: string) {
    await api.login(user, password)
    loggedIn.value = true
    username.value = user
  }

  async function logout() {
    await api.logout().catch(() => {})
    loggedIn.value = false
    username.value = ''
  }

  return { loggedIn, username, checked, me, login, logout }
})
