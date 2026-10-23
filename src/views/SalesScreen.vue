<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { daysAgoManila, formatDate, formatDateTime, formatTime, manilaDate } from '../lib/datetime'
import { formatPeso } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useSalesStore } from '../stores/sales'
import type { OrderStatus } from '../lib/types'

const auth = useAuthStore()
const sales = useSalesStore()
const from = ref(daysAgoManila(6))
const to = ref(manilaDate())
const status = ref<'all' | OrderStatus>('all')
const query = ref('')
const statusOptions: Array<{ value: 'all' | OrderStatus; label: string }> = [
  { value: 'all', label: 'All orders' },
  { value: 'completed', label: 'Completed' },
  { value: 'needs_review', label: 'Needs review' },
  { value: 'refunded', label: 'Refunded' },
  { value: 'voided', label: 'Voided' },
]

const eligible = computed(() =>
  sales.sales.filter((sale) => ['completed', 'refunded', 'voided'].includes(sale.status)),
)
const periodTotal = computed(() => eligible.value.reduce((sum, sale) => sum + sale.total_centavos, 0))
const refundedCount = computed(
  () => sales.sales.filter((sale) => sale.status === 'refunded' || sale.status === 'voided').length,
)
const reviewCount = computed(() => sales.sales.filter((sale) => sale.status === 'needs_review').length)
const filtered = computed(() => {
  const term = query.value.trim().toLowerCase()
  return sales.sales.filter((sale) => {
    if (status.value !== 'all' && sale.status !== status.value) return false
    if (!term) return true
    return [
      sale.id,
      sale.cashier_name ?? '',
      sale.payment_method_name ?? '',
      sale.status,
      ...sale.item_names,
    ]
      .join(' ')
      .toLowerCase()
      .includes(term)
  })
})

async function load() {
  if (!auth.activeBranchId) return
  await sales.loadSales(auth.activeBranchId, from.value, to.value, 200)
}

function exportCsv() {
  const rows = [
    ['Order', 'Date', 'Cashier', 'Payment', 'Status', 'Items', 'Total PHP'],
    ...filtered.value.map((sale) => [
      sale.id,
      formatDateTime(sale.created_at),
      sale.cashier_name ?? '',
      sale.payment_method_name ?? '',
      sale.status,
      sale.item_names.join('; '),
      (sale.total_centavos / 100).toFixed(2),
    ]),
  ]
  const csv = rows.map((row) => row.map((cell) => `"${String(cell).replaceAll('"', '""')}"`).join(',')).join('\n')
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = `benta-sales-${from.value}-to-${to.value}.csv`
  anchor.click()
  URL.revokeObjectURL(url)
}

watch([from, to, () => auth.activeBranchId], () => void load())
onMounted(() => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
        <h1>Sales</h1>
        <p class="subtle">Every order, correction, and offline review in one ledger.</p>
      </div>
      <div class="heading-actions">
        <button type="button" class="secondary small" :disabled="!filtered.length" @click="exportCsv">Export CSV</button>
        <button type="button" class="secondary small" :disabled="sales.loadingSales" @click="load">
          {{ sales.loadingSales ? 'Loading…' : 'Refresh' }}
        </button>
      </div>
    </div>

    <div class="panel filter-bar">
      <label><span>From</span><input v-model="from" type="date" /></label>
      <label><span>To</span><input v-model="to" type="date" /></label>
      <label class="grow"><span>Search</span><input v-model="query" type="search" placeholder="Item, cashier, status, or order id" /></label>
    </div>

    <div class="summary-strip">
      <article class="summary-card"><span>Period sales</span><strong>{{ formatPeso(periodTotal) }}</strong></article>
      <article class="summary-card"><span>Orders</span><strong>{{ eligible.length }}</strong></article>
      <article class="summary-card"><span>Needs review</span><strong>{{ reviewCount }}</strong></article>
      <article class="summary-card"><span>Void / refund</span><strong>{{ refundedCount }}</strong></article>
    </div>

    <div class="tabs" role="tablist" aria-label="Filter by status">
      <button
        v-for="item in statusOptions"
        :key="item.value"
        type="button"
        :class="{ active: status === item.value }"
        @click="status = item.value"
      >
        {{ item.label }}
      </button>
    </div>

    <div v-if="sales.error" class="callout danger">{{ sales.error }}</div>
    <div v-if="sales.loadingSales && !sales.sales.length" class="panel loading-panel">Loading sales…</div>
    <div v-else-if="!filtered.length" class="panel empty-panel">
      <h2>No matching orders</h2>
      <p>Change the date range or complete a sale in the cashier.</p>
      <RouterLink :to="{ name: 'pos' }" class="primary">Open cashier</RouterLink>
    </div>
    <div v-else class="panel table-panel">
      <div class="data-table sales-table">
        <div class="table-head">
          <span>Order</span><span>When</span><span>Items</span><span>Cashier</span><span>Payment</span><span>Total</span><span>Status</span>
        </div>
        <RouterLink
          v-for="sale in filtered"
          :key="sale.id"
          :to="{ name: 'order', params: { id: sale.id } }"
          class="table-row"
        >
          <span class="mono">#{{ sale.id.slice(0, 8).toUpperCase() }}</span>
          <span><b>{{ formatDate(sale.created_at) }}</b><small>{{ formatTime(sale.created_at) }}</small></span>
          <span><b>{{ sale.item_names.join(', ') || 'No lines' }}</b><small>{{ sale.item_count }} item{{ sale.item_count === 1 ? '' : 's' }}</small></span>
          <span>{{ sale.cashier_name ?? '—' }}</span>
          <span>{{ sale.payment_method_name ?? '—' }}</span>
          <span class="amount">{{ formatPeso(sale.total_centavos) }}</span>
          <span><span class="status-badge" :class="sale.status">{{ sale.status.replace('_', ' ') }}</span></span>
        </RouterLink>
      </div>
      <div class="mobile-sale-list">
        <RouterLink v-for="sale in filtered" :key="sale.id" :to="{ name: 'order', params: { id: sale.id } }" class="mobile-sale">
          <div>
            <strong>{{ sale.item_names.join(', ') || 'Order' }}</strong>
            <small>{{ formatDateTime(sale.created_at) }} · {{ sale.cashier_name ?? 'Team' }}</small>
          </div>
          <div>
            <b>{{ formatPeso(sale.total_centavos) }}</b>
            <span class="status-badge" :class="sale.status">{{ sale.status.replace('_', ' ') }}</span>
          </div>
        </RouterLink>
      </div>
    </div>
  </section>
</template>
