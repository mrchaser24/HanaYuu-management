<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { formatPeso } from '../lib/money'
import { formatTime, manilaDate } from '../lib/datetime'
import { useAuthStore } from '../stores/auth'
import { useOfflineStore } from '../stores/offline'
import { useSalesStore } from '../stores/sales'
import type { ScopeType } from '../lib/types'

const auth = useAuthStore()
const offline = useOfflineStore()
const sales = useSalesStore()

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
const activeScope = computed(() => scopeOptions.value.find((option) => option.type === selectedScope.value) ?? scopeOptions.value[0])
const metrics = computed(() => sales.metrics)
const greeting = computed(() => {
  const hour = Number(new Intl.DateTimeFormat('en-PH', { timeZone: 'Asia/Manila', hour: 'numeric', hour12: false }).format(new Date()))
  if (hour < 12) return 'Good morning'
  if (hour < 18) return 'Good afternoon'
  return 'Good evening'
})
const pendingTotal = computed(() => (metrics.value?.pending_sync_count ?? 0) + offline.pendingCount)
const topItems = computed(() => {
  const counts = new Map<string, number>()
  for (const sale of sales.recentSales) {
    for (const name of sale.item_names) counts.set(name, (counts.get(name) ?? 0) + 1)
  }
  return [...counts.entries()].sort((left, right) => right[1] - left[1]).slice(0, 4)
})
const breakdown = computed(() => {
  if (!metrics.value) return []
  const gross = Math.max(metrics.value.gross_sales_centavos, 1)
  return [
    { label: 'Net revenue', value: metrics.value.revenue_centavos, tone: 'green' },
    { label: 'Food cost', value: metrics.value.cogs_centavos, tone: 'gold' },
    { label: 'Expenses', value: metrics.value.expenses_centavos, tone: 'clay' },
    { label: 'Discounts', value: metrics.value.discounts_centavos, tone: 'slate' },
  ].map((item) => ({ ...item, width: Math.min((item.value / gross) * 100, 100) }))
})

async function load() {
  if (!activeScope.value) return
  loading.value = true
  await Promise.all([
    sales.loadMetrics(activeScope.value.type, activeScope.value.id, selectedDate.value),
    auth.activeBranch ? sales.loadRecent(auth.activeBranch.id) : Promise.resolve(),
    auth.activeBranch && auth.canManageBranch ? sales.loadPendingReviews(auth.activeBranch.id) : Promise.resolve(),
  ])
  loading.value = false
}

watch([selectedScope, selectedDate, () => auth.activeBranchId], () => void load())
watch(
  scopeOptions,
  (options) => {
    if (!options.some((option) => option.type === selectedScope.value) && options[0]) {
      selectedScope.value = options[0].type
    }
  },
  { immediate: true },
)
onMounted(() => void load())
</script>

<template>
  <section class="dashboard">
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }} · {{ selectedDate === manilaDate() ? 'Today' : selectedDate }}</p>
        <h1>{{ greeting }}, {{ auth.displayName.split(' ')[0] }}</h1>
        <p class="subtle">Here is how the business is doing.</p>
      </div>
      <div class="heading-actions">
        <select v-model="selectedScope" class="compact-select" aria-label="Dashboard scope">
          <option v-for="option in scopeOptions" :key="option.type" :value="option.type">{{ option.label }}</option>
        </select>
        <input v-model="selectedDate" class="compact-select" type="date" aria-label="Business date" />
        <button type="button" class="secondary small" :disabled="loading" @click="load">
          {{ loading ? 'Refreshing…' : 'Refresh' }}
        </button>
      </div>
    </div>

    <div v-if="auth.usingCachedContext" class="callout warning">
      Offline access is using your last saved permissions. Sales taken offline will sync when you reconnect.
    </div>
    <div v-if="!auth.activeBranch" class="callout warning">
      Your account has no branch assigned yet. Ask an owner to finish your team setup.
    </div>

    <div class="metric-grid">
      <article class="metric-card accent">
        <span>Net revenue</span>
        <strong>{{ formatPeso(metrics?.revenue_centavos ?? 0) }}</strong>
        <small>{{ metrics?.orders_count ?? 0 }} order{{ metrics?.orders_count === 1 ? '' : 's' }} · {{ formatPeso(metrics?.refunds_centavos ?? 0) }} refunded</small>
      </article>
      <article class="metric-card">
        <span>Net profit</span>
        <strong>{{ formatPeso(metrics?.net_profit_centavos ?? 0) }}</strong>
        <small>{{ metrics?.is_estimated ? 'Includes estimated costs' : 'After food cost and expenses' }}</small>
      </article>
      <article class="metric-card">
        <span>Inventory value</span>
        <strong>{{ formatPeso(metrics?.inventory_value_centavos ?? 0) }}</strong>
        <small>{{ metrics?.low_stock_count ?? 0 }} low-stock item{{ metrics?.low_stock_count === 1 ? '' : 's' }}</small>
      </article>
      <article class="metric-card">
        <span>Needs attention</span>
        <strong>{{ metrics?.pending_approvals_count ?? 0 }}</strong>
        <small>{{ pendingTotal }} sync item{{ pendingTotal === 1 ? '' : 's' }} · {{ metrics?.open_shifts_count ?? 0 }} open shift{{ metrics?.open_shifts_count === 1 ? '' : 's' }}</small>
      </article>
    </div>

    <div class="dashboard-columns">
      <article class="panel chart-panel">
        <div class="panel-title">
          <div><p class="eyebrow">Money flow</p><h2>Today at a glance</h2></div>
          <span>₱</span>
        </div>
        <div class="breakdown-list">
          <div v-for="item in breakdown" :key="item.label" class="breakdown-row">
            <div><span>{{ item.label }}</span><strong>{{ formatPeso(item.value) }}</strong></div>
            <div class="progress-track"><i :class="item.tone" :style="{ width: `${item.width}%` }"></i></div>
          </div>
        </div>
        <div class="split-stats">
          <div><span>Cash net</span><strong>{{ formatPeso(metrics?.cash_sales_centavos ?? 0) }}</strong></div>
          <div><span>GCash</span><strong>{{ formatPeso(metrics?.gcash_sales_centavos ?? 0) }}</strong></div>
          <div><span>Gross sales</span><strong>{{ formatPeso(metrics?.gross_sales_centavos ?? 0) }}</strong></div>
        </div>
      </article>

      <article class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">Fast actions</p><h2>Keep it moving</h2></div>
        </div>
        <div class="quick-actions">
          <RouterLink :to="{ name: 'pos' }" class="quick-action"><b>New sale</b><span>Open the cashier</span></RouterLink>
          <RouterLink :to="{ name: 'cash' }" class="quick-action"><b>Cash drawer</b><span>Shift and payouts</span></RouterLink>
          <RouterLink :to="{ name: 'inventory' }" class="quick-action"><b>Receive stock</b><span>Record a restock</span></RouterLink>
          <RouterLink v-if="auth.canViewReports" :to="{ name: 'reports' }" class="quick-action"><b>Reports</b><span>Profit and cash</span></RouterLink>
        </div>
        <ol v-if="topItems.length" class="popular-list top-items">
          <li v-for="([name, count], index) in topItems" :key="name">
            <b>{{ index + 1 }}</b><span>{{ name }}</span><strong>{{ count }} order{{ count === 1 ? '' : 's' }}</strong>
          </li>
        </ol>
        <p v-else class="empty-state">Item trends appear after today's first sales.</p>
      </article>
    </div>

    <div class="dashboard-columns lower">
      <article class="panel activity-panel">
        <div class="panel-title">
          <div><p class="eyebrow">Live activity</p><h2>Recent sales</h2></div>
          <RouterLink :to="{ name: 'sales' }" class="text-link">View all</RouterLink>
        </div>
        <div v-if="sales.recentSales.length" class="activity-list">
          <RouterLink
            v-for="sale in sales.recentSales.slice(0, 6)"
            :key="sale.id"
            :to="{ name: 'order', params: { id: sale.id } }"
            class="activity-item"
          >
            <div class="activity-icon">{{ sale.payment_method_kind === 'cash' ? '₱' : 'G' }}</div>
            <div>
              <strong>{{ sale.item_names.join(', ') || 'Order' }}</strong>
              <small>{{ sale.cashier_name ?? 'Team' }} · {{ formatTime(sale.captured_at) }} · {{ sale.item_count }} item{{ sale.item_count === 1 ? '' : 's' }}</small>
            </div>
            <div class="activity-amount">
              <strong>{{ formatPeso(sale.total_centavos) }}</strong>
              <small :class="sale.status">{{ sale.status.replace('_', ' ') }}</small>
            </div>
          </RouterLink>
        </div>
        <div v-else class="empty-state">No sales yet. Start from the cashier when you are ready.</div>
      </article>

      <article v-if="auth.canManageBranch" class="panel">
        <div class="panel-title">
          <div><p class="eyebrow">Owner review</p><h2>Needs a decision</h2></div>
          <span>{{ sales.pendingReviews.length }}</span>
        </div>
        <div v-if="sales.pendingReviews.length" class="review-list">
          <RouterLink
            v-for="review in sales.pendingReviews.slice(0, 5)"
            :key="review.id"
            :to="{ name: 'order', params: { id: review.id } }"
            class="review-item"
          >
            <div>
              <strong>{{ review.item_names.join(', ') || 'Offline order' }}</strong>
              <small>{{ review.cashier_name ?? 'Team' }} · {{ review.review_reason || 'Offline conflict' }}</small>
            </div>
            <b>{{ formatPeso(review.total_centavos) }}</b>
          </RouterLink>
        </div>
        <div v-else class="empty-state">No offline orders need review.</div>
        <div class="inline-links">
          <RouterLink :to="{ name: 'cash' }" class="text-link">{{ metrics?.pending_approvals_count ?? 0 }} approvals</RouterLink>
          <RouterLink :to="{ name: 'corrections' }" class="text-link">Corrections</RouterLink>
        </div>
      </article>
    </div>
  </section>
</template>
