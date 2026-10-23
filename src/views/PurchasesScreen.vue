<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { getPurchases } from '../lib/api'
import { daysAgoManila, formatDate, formatDateTime, manilaDate } from '../lib/datetime'
import { formatPeso } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import type { PurchaseRow } from '../lib/types'

const auth = useAuthStore()

const purchases = ref<PurchaseRow[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const from = ref(daysAgoManila(29))
const to = ref(manilaDate())

async function load() {
  if (!auth.activeBranchId) return
  loading.value = true
  error.value = null
  try {
    purchases.value = await getPurchases(auth.activeBranchId, from.value, to.value)
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : String(loadError)
    purchases.value = []
  } finally {
    loading.value = false
  }
}

const restockTotal = computed(() =>
  purchases.value.filter((p) => p.type === 'restock').reduce((sum, p) => sum + p.base_cost_centavos, 0),
)
const expenseTotal = computed(() =>
  purchases.value.filter((p) => p.type === 'expense').reduce((sum, p) => sum + p.base_cost_centavos, 0),
)
const deliveryFeeTotal = computed(() =>
  purchases.value.reduce((sum, p) => sum + p.delivery_fee_centavos, 0),
)
const grandTotal = computed(() =>
  purchases.value.reduce((sum, p) => sum + p.total_deducted_centavos, 0),
)

onMounted(() => void load())
watch([from, to, () => auth.activeBranchId], () => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
        <h1>Purchases &amp; Costs</h1>
        <p class="subtle">Restocks, supply purchases, and delivery fees paid from the cash drawer.</p>
      </div>
      <div class="heading-actions">
        <button type="button" class="secondary small" :disabled="loading" @click="load">
          {{ loading ? 'Refreshing…' : 'Refresh' }}
        </button>
      </div>
    </div>

    <div class="panel filter-bar">
      <label><span>From</span><input v-model="from" type="date" /></label>
      <label><span>To</span><input v-model="to" type="date" /></label>
      <div class="filter-summary"><span>Total deducted</span><strong>{{ formatPeso(grandTotal) }}</strong></div>
    </div>

    <div class="summary-strip">
      <article class="summary-card"><span>Restock cost</span><strong>{{ formatPeso(restockTotal) }}</strong></article>
      <article class="summary-card"><span>Supply cost</span><strong>{{ formatPeso(expenseTotal) }}</strong></article>
      <article class="summary-card"><span>Delivery fees</span><strong>{{ formatPeso(deliveryFeeTotal) }}</strong></article>
      <article class="summary-card"><span>Total deducted</span><strong>{{ formatPeso(grandTotal) }}</strong></article>
    </div>

    <div v-if="error" class="callout danger">{{ error }}</div>
    <div v-if="loading && !purchases.length" class="panel loading-panel">Loading purchases…</div>
    <div v-else-if="!purchases.length" class="panel empty-panel">
      <h2>No purchases in this period</h2>
      <p>Record stock restocks or expenses to see them here.</p>
    </div>
    <div v-else class="panel table-panel">
      <div class="data-table eight-col">
        <div class="table-head">
          <span>Date</span><span>Type</span><span>Supplier / Category</span><span>Description</span><span>Items</span><span>Base cost</span><span>Delivery fee</span><span>Total</span><span>Recorded by</span>
        </div>
        <div v-for="p in purchases" :key="p.id" class="table-row static">
          <span>{{ formatDate(p.purchase_date) }}<small>{{ formatDateTime(p.purchase_date).split(', ').at(-1) }}</small></span>
          <span><span class="status-badge neutral">{{ p.type === 'restock' ? 'Restock' : 'Expense' }}</span></span>
          <span>{{ p.supplier_category }}</span>
          <span>{{ p.description }}</span>
          <span>{{ p.items }}</span>
          <span class="amount">{{ formatPeso(p.base_cost_centavos) }}</span>
          <span class="amount">{{ formatPeso(p.delivery_fee_centavos) }}</span>
          <span class="amount">{{ formatPeso(p.total_deducted_centavos) }}</span>
          <span>{{ p.created_by_name ?? '—' }}</span>
        </div>
      </div>
    </div>
  </section>
</template>
