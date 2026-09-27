import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from './stores/auth'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', component: () => import('./views/Login.vue'), meta: { bare: true } },
    { path: '/', component: () => import('./views/Overview.vue') },
    { path: '/users', component: () => import('./views/Users.vue') },
    { path: '/nodes', component: () => import('./views/Nodes.vue') },
    { path: '/server', component: () => import('./views/Server.vue') },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

router.beforeEach(async (to) => {
  const auth = useAuthStore()
  if (!auth.checked) await auth.me()
  if (to.path !== '/login' && !auth.loggedIn) return '/login'
  if (to.path === '/login' && auth.loggedIn) return '/'
})

export default router
