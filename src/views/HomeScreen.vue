<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { RouterLink } from 'vue-router'
import { formatPeso } from '../lib/money'
import { formatTime, manilaDate } from '../lib/datetime'
import { useAuthStore } from '../stores/auth'
import { useSalesStore } from '../stores/sales'
import { useOfflineStore } from '../stores/offline'
import type { ScopeType } from '../lib/types'

const auth = useAuthStore()
const sales = useSalesStore()
const offline = useOfflineStore()

const selectedScope = ref<ScopeType>('branch')
const selectedDate = ref(manilaDate())
const loading = ref(false)

const scopeOptions = computed(() => {
  const options: Array<{ type: ScopeType; id: string; label: string }> = []
  if (auth.activeBranch) options.push({ type: 'branch', id: auth.activeBranch.id, label: 'This branch' })
  if (auth.activeShop && auth.canManageShop) options.push({ type: 'shop', id: auth.activeShop.id, label: 'Whole shop' })
  if (auth.activeGroup && auth.isSuperAdmin) options.push({ type: 'group', id: auth.activeGroup.id, label: 'All shops' })
  return options
})

const activeScope = computed(
  () => scopeOptions.value.find((o) => o.type === selectedScope.value) ?? scopeOptions.value[0],
)

const m = computed(() => sales.metrics)

const greeting = computed(() => {
  const hour = Number(
    new Intl.DateTimeFormat('en-PH', { timeZone: 'Asia/Manila', hour: 'numeric', hour12: false }).format(new Date()),
  )
  if (hour < 12) return 'Good morning'
  if (hour < 18) return 'Good afternoon'
  return 'Good evening'
})

const isToday = computed(() => selectedDate.value === manilaDate())

const profitStatus = computed(() => {
  if (!m.value) return { icon: '—', text: 'No activity yet', tone: '' }
  const net = m.value.net_profit_centavos
  if (net > 0) return { icon: '📈', text: 'Earning today', tone: 'success' }
  if (net < 0) return { icon: '📉', text: 'Losing today', tone: 'warning' }
  return { icon: '—', text: 'No activity yet', tone: '' }
})

const moneyFlow = computed(() => {
  if (!m.value) return []
  return [
    { label: 'Money In (Gross Sales)', value: m.value.gross_sales_centavos },
    { label: 'Food Cost', value: -m.value.cogs_centavos },
    { label: 'Expenses', value: -m.value.expenses_centavos },
    { label: 'Net Profit', value: m.value.net_profit_centavos },
  ]
})

const alerts = computed(() => {
  if (!m.value) return []
  const list: Array<{ icon: string; text: string; tone: string }> = []
  if (m.value.low_stock_count > 0)
    list.push({ icon: '📦', text: `${m.value.low_stock_count} items low on stock`, tone: 'warning' })
  if (m.value.pending_approvals_count > 0)
    list.push({ icon: '⏳', text: `${m.value.pending_approvals_count} need approval`, tone: 'warning' })
  if (m.value.open_shifts_count > 0)
    list.push({ icon: '🔓', text: `${m.value.open_shifts_count} shifts still open`, tone: 'warning' })
  const pendingSync = (m.value.pending_sync_count ?? 0) + offline.pendingCount
  if (pendingSync > 0)
    list.push({ icon: '🔄', text: `${pendingSync} sales pending sync`, tone: 'warning' })
  return list
})

const recentFive = computed(() => sales.recentSales.slice(0, 5))

async function load() {
  if (!activeScope.value) return
  loading.value = true
  await Promise.all([
    sales.loadMetrics(activeScope.value.type, activeScope.value.id, selectedDate.value),
    auth.activeBranch ? sales.loadRecent(auth.activeBranch.id) : Promise.resolve(),
    auth.activeBranch && auth.canManageBranch
      ? sales.loadPendingReviews(auth.activeBranch.id)
      : Promise.resolve(),
  ])
  loading.value = false
}

watch([selectedScope, selectedDate, () => auth.activeBranchId, () => auth.activeShopId], () => void load())
watch(
  scopeOptions,
  (options) => {
    if (!options.some((o) => o.type === selectedScope.value) && options[0]) {
      selectedScope.value = options[0].type
    }
  },
  { immediate: true },
)
onMounted(() => void load())

function onScopeChange(event: Event) {
  selectedScope.value = (event.target as HTMLSelectElement).value as ScopeType
}
</script>

<template>
  <section class="home-screen">
    <!-- Header -->
    <div class="section-heading">
      <div>
        <p class="eyebrow">
          {{ auth.activeBranch?.name ?? 'No branch' }} ·
          {{ isToday ? 'Today' : selectedDate }}
        </p>
        <h1>{{ greeting }}, {{ auth.displayName.split(' ')[0] }}</h1>
      </div>
      <div class="heading-actions">
        <select
          v-if="scopeOptions.length > 1"
          class="compact-select"
          :value="selectedScope"
          @change="onScopeChange"
        >
          <option v-for="opt in scopeOptions" :key="opt.type" :value="opt.type">
            {{ opt.label }}
          </option>
        </select>
        <input type="date" class="compact-select" v-model="selectedDate" />
      </div>
    </div>

    <p v-if="auth.usingCachedContext" class="subtle">Using cached data — connect to refresh.</p>

    <!-- Big numbers -->
    <div v-if="m" class="metric-grid">
      <div class="metric-card accent">
        <span class="eyebrow">Today's Sales</span>
        <strong>{{ formatPeso(m.revenue_centavos) }}</strong>
        <span class="subtle">{{ m.orders_count }} orders</span>
      </div>
      <div class="metric-card">
        <span class="eyebrow">Today's Profit</span>
        <strong>{{ formatPeso(m.net_profit_centavos) }}</strong>
        <span v-if="m.is_estimated" class="subtle">⚠ estimated</span>
      </div>
      <div class="metric-card">
        <span class="eyebrow">Cash on Hand</span>
        <strong>{{ formatPeso(m.cash_sales_centavos) }}</strong>
        <span class="subtle">GCash: {{ formatPeso(m.gcash_sales_centavos) }}</span>
      </div>
    </div>
    <div v-else-if="loading" class="metric-grid">
      <div class="metric-card"><span class="subtle">Loading…</span></div>
    </div>

    <!-- Earning / Losing banner -->
    <div
      v-if="m"
      class="callout"
      :class="{ warning: profitStatus.tone === 'warning' }"
    >
      {{ profitStatus.icon }} {{ profitStatus.text }}
    </div>

    <!-- Money flow -->
    <div v-if="m" class="panel">
      <h3 class="panel-title">Money Flow</h3>
      <ul class="activity-list">
        <li v-for="row in moneyFlow" :key="row.label" class="activity-item">
          <span>{{ row.label }}</span>
          <span class="activity-amount">{{ formatPeso(Math.abs(row.value)) }}</span>
        </li>
      </ul>
    </div>

    <!-- Alerts -->
    <div v-if="alerts.length" class="panel">
      <h3 class="panel-title">Alerts</h3>
      <div class="home-alerts">
        <span v-for="(a, i) in alerts" :key="i" class="pill warning">
          {{ a.icon }} {{ a.text }}
        </span>
      </div>
    </div>

    <!-- Recent activity -->
    <div class="panel">
      <h3 class="panel-title">Recent Sales</h3>
      <ul v-if="recentFive.length" class="activity-list">
        <li v-for="sale in recentFive" :key="sale.id" class="activity-item">
          <RouterLink :to="{ name: 'order', params: { id: sale.id } }" class="activity-link">
            <span class="activity-icon">
              {{ sale.payment_method_kind === 'gcash' ? '📱' : '💵' }}
            </span>
            <span class="activity-detail">
              <span>{{ sale.item_names.slice(0, 2).join(', ') }}{{ sale.item_count > 2 ? ` +${sale.item_count - 2}` : '' }}</span>
              <span class="subtle">{{ sale.cashier_name ?? 'Staff' }} · {{ formatTime(sale.captured_at) }}</span>
            </span>
            <span class="activity-amount">{{ formatPeso(sale.total_centavos) }}</span>
          </RouterLink>
        </li>
      </ul>
      <p v-else class="empty-state">No recent sales yet.</p>
    </div>

    <!-- Quick links -->
    <div class="quick-actions">
      <RouterLink :to="{ name: 'pos' }" class="quick-action">➕ New Sale</RouterLink>
      <RouterLink :to="{ name: 'history' }" class="quick-action">📋 History</RouterLink>
      <RouterLink :to="{ name: 'record' }" class="quick-action">📝 Record</RouterLink>
    </div>
  </section>
</template>

<style scoped>
.home-screen {
  max-width: 640px;
  margin: 0 auto;
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.home-alerts {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

.activity-link {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: 100%;
  text-decoration: none;
  color: inherit;
}

.activity-detail {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.activity-detail > span:first-child {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
