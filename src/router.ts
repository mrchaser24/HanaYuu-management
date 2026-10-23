import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from './stores/auth'
import DashboardScreen from './views/DashboardScreen.vue'
import PosScreen from './views/PosScreen.vue'
import SalesScreen from './views/SalesScreen.vue'
import OrderDetailScreen from './views/OrderDetailScreen.vue'
import InventoryScreen from './views/InventoryScreen.vue'
import ProductionScreen from './views/ProductionScreen.vue'
import CashScreen from './views/CashScreen.vue'
import CorrectionsScreen from './views/CorrectionsScreen.vue'
import ExpensesScreen from './views/ExpensesScreen.vue'
import ReportsScreen from './views/ReportsScreen.vue'
import AdminScreen from './views/AdminScreen.vue'
import MoreScreen from './views/MoreScreen.vue'
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
    { path: '/', name: 'dashboard', component: DashboardScreen, meta: { title: 'Overview' } },
    { path: '/pos', name: 'pos', component: PosScreen, meta: { title: 'Cashier' } },
    { path: '/sales', name: 'sales', component: SalesScreen, meta: { title: 'Sales' } },
    { path: '/sales/:id', name: 'order', component: OrderDetailScreen, meta: { title: 'Order' } },
    { path: '/inventory', name: 'inventory', component: InventoryScreen, meta: { title: 'Inventory' } },
    { path: '/production', name: 'production', component: ProductionScreen, meta: { title: 'Production' } },
    { path: '/cash', name: 'cash', component: CashScreen, meta: { title: 'Cash drawer' } },
    {
      path: '/corrections',
      name: 'corrections',
      component: CorrectionsScreen,
      meta: { ownerOnly: true, title: 'Corrections' },
    },
    { path: '/expenses', name: 'expenses', component: ExpensesScreen, meta: { title: 'Expenses' } },
    {
      path: '/reports',
      name: 'reports',
      component: ReportsScreen,
      meta: { ownerOnly: true, title: 'Reports' },
    },
    { path: '/admin', name: 'admin', component: AdminScreen, meta: { ownerOnly: true, title: 'Admin' } },
    { path: '/more', name: 'more', component: MoreScreen, meta: { title: 'More' } },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
  scrollBehavior: () => ({ top: 0 }),
})

router.beforeEach(async (to) => {
  const auth = useAuthStore()
  if (!auth.initialized) await auth.init()
  if (to.meta.public) {
    return auth.isAuthenticated ? { name: 'dashboard' } : true
  }
  if (!auth.isAuthenticated) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }
  if (to.meta.ownerOnly && !auth.isOwner) return { name: 'dashboard' }
  return true
})

router.afterEach((to) => {
  document.title = to.meta.title ? `${to.meta.title} · Benta` : 'Benta Business Control'
})
