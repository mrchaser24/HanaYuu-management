import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from './stores/auth'
import HomeScreen from './views/HomeScreen.vue'
import PosScreen from './views/PosScreen.vue'
import OrderDetailScreen from './views/OrderDetailScreen.vue'
import RecordScreen from './views/RecordScreen.vue'
import HistoryScreen from './views/HistoryScreen.vue'
import SettingsScreen from './views/SettingsScreen.vue'
import LoginScreen from './views/LoginScreen.vue'

declare module 'vue-router' {
  interface RouteMeta {
    public?: boolean
    ownerOnly?: boolean
    title?: string
  }
}

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: LoginScreen, meta: { public: true, title: 'Sign in' } },
    { path: '/', name: 'home', component: HomeScreen, meta: { title: 'Home' } },
    { path: '/sell', name: 'pos', component: PosScreen, meta: { title: 'Sell' } },
    { path: '/record', name: 'record', component: RecordScreen, meta: { title: 'Record' } },
    { path: '/history', name: 'history', component: HistoryScreen, meta: { title: 'History' } },
    { path: '/history/:id', name: 'order', component: OrderDetailScreen, meta: { title: 'Order' } },
    { path: '/settings', name: 'settings', component: SettingsScreen, meta: { title: 'Settings' } },
    // Legacy redirects
    { path: '/pos', redirect: '/sell' },
    { path: '/sales', redirect: '/history' },
    { path: '/sales/:id', redirect: to => `/history/${to.params.id}` },
    { path: '/inventory', redirect: '/record' },
    { path: '/production', redirect: '/record' },
    { path: '/cash', redirect: '/record' },
    { path: '/expenses', redirect: '/record' },
    { path: '/purchases', redirect: '/history' },
    { path: '/corrections', redirect: '/settings' },
    { path: '/reports', redirect: '/settings' },
    { path: '/admin', redirect: '/settings' },
    { path: '/more', redirect: '/settings' },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
  scrollBehavior: () => ({ top: 0 }),
})

router.beforeEach(async (to) => {
  const auth = useAuthStore()
  if (!auth.initialized) await auth.init()
  if (to.meta.public) {
    return auth.isAuthenticated ? { name: 'home' } : true
  }
  if (!auth.isAuthenticated) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }
  if (to.meta.ownerOnly && !auth.isOwner) return { name: 'home' }
  return true
})

router.afterEach((to) => {
  document.title = to.meta.title ? `${to.meta.title} · Benta` : 'Benta Business Control'
})
