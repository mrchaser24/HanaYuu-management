<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import AppHeader from './components/AppHeader.vue'
import BottomNavigation from './components/BottomNavigation.vue'
import ToastStack from './components/ToastStack.vue'
import { useAuthStore } from './stores/auth'
import { useCartStore } from './stores/cart'
import { useCatalogStore } from './stores/catalog'
import { useOfflineStore } from './stores/offline'
import { useSalesStore } from './stores/sales'
import { useUiStore } from './stores/ui'

const auth = useAuthStore()
const cart = useCartStore()
const catalog = useCatalogStore()
const offline = useOfflineStore()
const sales = useSalesStore()
const ui = useUiStore()
const route = useRoute()

const isLogin = computed(() => route.name === 'login')
const showShell = computed(() => auth.isAuthenticated && !isLogin.value)
const syncMessage = computed(() => {
  if (!offline.pendingCount) return ''
  if (!ui.online) return `${offline.pendingCount} sale${offline.pendingCount === 1 ? '' : 's'} encrypted on this device.`
  if (offline.needsUnlock) return `${offline.pendingCount} saved sale${offline.pendingCount === 1 ? '' : 's'} locked. Unlock to sync.`
  return `${offline.pendingCount} sale${offline.pendingCount === 1 ? '' : 's'} waiting to sync.`
})

async function trySync() {
  if (!ui.online || !auth.isAuthenticated || !offline.unlocked || !offline.pendingCount) return
  try {
    const result = await offline.syncPending()
    if (result.accepted > 0) {
      ui.success(`${result.accepted} offline sale${result.accepted === 1 ? '' : 's'} synced`, 'Stock, cash, and reports are up to date.')
    }
    if (result.needsReview > 0) {
      ui.notify(
        `${result.needsReview} offline sale${result.needsReview === 1 ? '' : 's'} saved for review`,
        'Stock was not deducted. Open Sales to review the order.',
        'warning',
      )
    }
    if (offline.lastSyncError) ui.error('Some sales still need attention', offline.lastSyncError)
    if (result.accepted > 0 && sales.metrics) void sales.loadMetrics(sales.metrics.scope_type, sales.metrics.scope_id)
  } catch (error) {
    ui.error('Sync paused', error instanceof Error ? error.message : String(error))
  }
}

function updateOnlineStatus() {
  ui.setOnline(navigator.onLine)
  if (navigator.onLine) {
    void auth.refreshContext().then(() => offline.inspectDevice()).catch(() => undefined)
    void trySync()
  }
}

function onVisibility() {
  if (document.visibilityState === 'visible' && navigator.onLine) void trySync()
}

watch(
  () => auth.isAuthenticated,
  async (isAuthenticated) => {
    if (!isAuthenticated) {
      offline.lock()
      cart.clear()
      catalog.clear()
      sales.clear()
      return
    }
    await offline.init()
    await offline.inspectDevice()
    await trySync()
  },
  { immediate: true },
)

watch(
  () => auth.activeBranchId,
  async (branchId, previous) => {
    if (branchId === previous) return
    cart.clear()
    if (branchId) {
      await offline.inspectDevice()
      await trySync()
    }
  },
)

onMounted(() => {
  window.addEventListener('online', updateOnlineStatus)
  window.addEventListener('offline', updateOnlineStatus)
  document.addEventListener('visibilitychange', onVisibility)
  updateOnlineStatus()
})

onBeforeUnmount(() => {
  window.removeEventListener('online', updateOnlineStatus)
  window.removeEventListener('offline', updateOnlineStatus)
  document.removeEventListener('visibilitychange', onVisibility)
})
</script>

<template>
  <div :class="{ 'app-shell': showShell }">
    <a v-if="showShell" class="skip-link" href="#main-content">Skip to content</a>
    <AppHeader v-if="showShell" />
    <main id="main-content" :class="showShell ? 'app-main' : 'auth-main'">
      <RouterView />
    </main>
    <BottomNavigation v-if="showShell" />
    <button
      v-if="showShell && syncMessage"
      type="button"
      class="sync-banner"
      :class="{ locked: offline.needsUnlock }"
      @click="$router.push({ name: 'more' })"
    >
      {{ syncMessage }}
    </button>
    <ToastStack />
  </div>
</template>
