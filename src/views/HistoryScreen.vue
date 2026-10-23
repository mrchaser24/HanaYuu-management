<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { getSalesHistory, getPurchases, getCorrections, getExpenses } from '../lib/api'
import { daysAgoManila, formatDate, formatTime, manilaDate } from '../lib/datetime'
import { formatPeso } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import type { SaleSummary, PurchaseRow, Correction, Expense } from '../lib/types'

type EntryType = 'sale' | 'restock' | 'expense' | 'correction'
type TabFilter = 'all' | EntryType

interface TimelineEntry {
  id: string
  type: EntryType
  label: string
  amount: number
  method?: string
  date: string
  status?: string
  orderId?: string
}

const auth = useAuthStore()

const from = ref(daysAgoManila(6))
const to = ref(manilaDate())
const tab = ref<TabFilter>('all')
const loading = ref(false)
const error = ref<string | null>(null)

const rawSales = ref<SaleSummary[]>([])
const rawPurchases = ref<PurchaseRow[]>([])
const rawCorrections = ref<Correction[]>([])
const rawExpenses = ref<Expense[]>([])

const tabs: Array<{ value: TabFilter; label: string }> = [
  { value: 'all', label: 'All' },
  { value: 'sale', label: 'Sales' },
  { value: 'restock', label: 'Purchases' },
  { value: 'expense', label: 'Expenses' },
  { value: 'correction', label: 'Corrections' },
]

async function load() {
  if (!auth.activeBranchId) return
  loading.value = true
  error.value = null
  try {
    const [s, p, c, e] = await Promise.all([
      getSalesHistory(auth.activeBranchId, from.value, to.value, 500),
      getPurchases(auth.activeBranchId, from.value, to.value),
      getCorrections(auth.activeBranchId),
      getExpenses(auth.activeBranchId, from.value, to.value),
    ])
    rawSales.value = s
    rawPurchases.value = p
    rawCorrections.value = c
    rawExpenses.value = e
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
  } finally {
    loading.value = false
  }
}

const entries = computed<TimelineEntry[]>(() => {
  const items: TimelineEntry[] = []

  for (const s of rawSales.value) {
    if (!['completed', 'refunded', 'voided'].includes(s.status)) continue
    items.push({
      id: s.id,
      type: 'sale',
      label: s.item_names.length
        ? s.item_names.join(', ')
        : `${s.item_count} item${s.item_count === 1 ? '' : 's'}`,
      amount: s.total_centavos,
      method: s.payment_method_kind ?? undefined,
      date: s.captured_at,
      status: s.status,
      orderId: s.id,
    })
  }

  for (const p of rawPurchases.value) {
    if (p.type !== 'restock') continue
    items.push({
      id: p.id,
      type: 'restock',
      label: p.description || p.supplier_category || 'Restock',
      amount: -p.total_deducted_centavos,
      date: p.purchase_date,
    })
  }

  for (const e of rawExpenses.value) {
    items.push({
      id: e.id,
      type: 'expense',
      label: e.description || e.category,
      amount: -(e.amount_centavos + e.delivery_fee_centavos),
      date: e.spent_at,
    })
  }

  for (const c of rawCorrections.value) {
    items.push({
      id: c.id,
      type: 'correction',
      label: `${c.kind === 'void' ? 'Void' : 'Refund'}: ${c.reason}`,
      amount: -(c.refund_amount_centavos ?? c.order_total_centavos),
      method: c.refund_method ?? undefined,
      date: c.created_at,
      status: c.status,
      orderId: c.order_id,
    })
  }

  items.sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
  return items
})

const filtered = computed(() => {
  if (tab.value === 'all') return entries.value
  return entries.value.filter((e) => e.type === tab.value)
})

const totalIn = computed(() =>
  filtered.value.filter((e) => e.amount > 0).reduce((sum, e) => sum + e.amount, 0),
)
const totalOut = computed(() =>
  filtered.value.filter((e) => e.amount < 0).reduce((sum, e) => sum + e.amount, 0),
)
const net = computed(() => totalIn.value + totalOut.value)

const grouped = computed(() => {
  const groups: Array<{ date: string; items: TimelineEntry[] }> = []
  let currentDate = ''
  for (const entry of filtered.value) {
    const d = formatDate(entry.date)
    if (d !== currentDate) {
      currentDate = d
      groups.push({ date: d, items: [] })
    }
    groups[groups.length - 1].items.push(entry)
  }
  return groups
})

function icon(entry: TimelineEntry): string {
  if (entry.type === 'sale') return entry.method === 'gcash' ? 'G' : '₱'
  if (entry.type === 'restock') return '📦'
  if (entry.type === 'expense') return '💸'
  return '↩'
}

watch([from, to, () => auth.activeBranchId], () => void load())
onMounted(() => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
        <h1>History</h1>
      </div>
      <div class="heading-actions">
        <label><span class="sr-only">From</span><input v-model="from" type="date" class="compact-select" /></label>
        <label><span class="sr-only">To</span><input v-model="to" type="date" class="compact-select" /></label>
      </div>
    </div>

    <div class="tabs" role="tablist" aria-label="Filter by type">
      <button
        v-for="t in tabs"
        :key="t.value"
        type="button"
        :class="{ active: tab === t.value }"
        @click="tab = t.value"
      >
        {{ t.label }}
      </button>
    </div>

    <div class="metric-grid">
      <article class="metric-card">
        <span>Total In</span>
        <strong class="amount-in">{{ formatPeso(totalIn) }}</strong>
      </article>
      <article class="metric-card">
        <span>Total Out</span>
        <strong class="amount-out">{{ formatPeso(Math.abs(totalOut)) }}</strong>
      </article>
      <article class="metric-card accent">
        <span>Net</span>
        <strong :class="net >= 0 ? 'amount-in' : 'amount-out'">{{ formatPeso(Math.abs(net)) }}</strong>
      </article>
    </div>

    <div v-if="error" class="callout danger">{{ error }}</div>

    <div v-if="loading && !entries.length" class="panel empty-state">Loading history…</div>

    <div v-else-if="!filtered.length" class="panel empty-state">
      <h2>No activity found</h2>
      <p>Adjust the date range or make a sale to see entries here.</p>
    </div>

    <template v-else>
      <div v-for="group in grouped" :key="group.date" class="panel">
        <h3 class="eyebrow group-date">{{ group.date }}</h3>
        <ul class="activity-list">
          <li v-for="entry in group.items" :key="entry.id" class="activity-item">
            <span class="activity-icon" :class="entry.type">{{ icon(entry) }}</span>

            <div class="activity-body">
              <RouterLink
                v-if="entry.orderId"
                :to="{ name: 'order', params: { id: entry.orderId } }"
                class="activity-label"
              >
                {{ entry.label }}
              </RouterLink>
              <span v-else class="activity-label">{{ entry.label }}</span>

              <span v-if="entry.status && entry.type === 'correction'" class="status-badge" :class="entry.status">
                {{ entry.status }}
              </span>
            </div>

            <span class="activity-amount" :class="entry.amount >= 0 ? 'positive' : 'negative'">
              {{ entry.amount >= 0 ? '+' : '−' }}{{ formatPeso(Math.abs(entry.amount)) }}
            </span>

            <span v-if="entry.method" class="activity-method">{{ entry.method === 'gcash' ? 'GCash' : 'Cash' }}</span>
            <span v-else class="activity-method"></span>

            <time class="activity-time">{{ formatTime(entry.date) }}</time>
          </li>
        </ul>
      </div>
    </template>
  </section>
</template>

<style scoped>
.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
}

.metric-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 0.75rem;
  margin-bottom: 1rem;
}

.amount-in {
  color: var(--color-success, #16a34a);
}

.amount-out {
  color: var(--color-danger, #dc2626);
}

.group-date {
  margin-bottom: 0.5rem;
}

.activity-list {
  list-style: none;
  padding: 0;
  margin: 0;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.activity-item {
  display: grid;
  grid-template-columns: 2rem 1fr auto auto auto;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem 0;
  border-bottom: 1px solid var(--color-border, #e5e7eb);
}

.activity-item:last-child {
  border-bottom: none;
}

.activity-icon {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 2rem;
  height: 2rem;
  border-radius: 50%;
  font-size: 0.85rem;
  font-weight: 600;
  background: var(--color-surface, #f3f4f6);
}

.activity-icon.sale {
  background: #dcfce7;
  color: #16a34a;
}

.activity-icon.restock {
  background: #dbeafe;
  color: #2563eb;
}

.activity-icon.expense {
  background: #fef3c7;
  color: #d97706;
}

.activity-icon.correction {
  background: #fce7f3;
  color: #db2777;
}

.activity-body {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  min-width: 0;
}

.activity-label {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

a.activity-label {
  color: inherit;
  text-decoration: none;
}

a.activity-label:hover {
  text-decoration: underline;
}

.activity-amount {
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.activity-amount.positive {
  color: var(--color-success, #16a34a);
}

.activity-amount.negative {
  color: var(--color-danger, #dc2626);
}

.activity-method {
  font-size: 0.8rem;
  color: var(--color-muted, #6b7280);
  min-width: 3rem;
  text-align: center;
}

.activity-time {
  font-size: 0.8rem;
  color: var(--color-muted, #6b7280);
  white-space: nowrap;
}

@media (max-width: 640px) {
  .metric-grid {
    grid-template-columns: 1fr;
  }

  .activity-item {
    grid-template-columns: 2rem 1fr auto;
    grid-template-rows: auto auto;
  }

  .activity-method,
  .activity-time {
    grid-row: 2;
  }

  .activity-method {
    grid-column: 2;
  }

  .activity-time {
    grid-column: 3;
  }
}
</style>
