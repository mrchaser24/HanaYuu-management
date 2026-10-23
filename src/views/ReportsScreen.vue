<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { getReports } from '../lib/api'
import { daysAgoManila, formatDate, formatQuantity, manilaDate } from '../lib/datetime'
import { formatPeso, formatPercentFromBasisPoints } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import type { ReportResponse, ScopeType } from '../lib/types'

const auth = useAuthStore()
const report = ref<ReportResponse | null>(null)
const from = ref(daysAgoManila(29))
const to = ref(manilaDate())
const selectedScope = ref<ScopeType>('branch')
const loading = ref(false)
const error = ref<string | null>(null)

const scopeOptions = computed(() => {
  const options: Array<{ type: ScopeType; id: string; label: string }> = []
  if (auth.activeBranch) options.push({ type: 'branch', id: auth.activeBranch.id, label: 'This branch' })
  if (auth.activeShop && auth.canManageShop) options.push({ type: 'shop', id: auth.activeShop.id, label: 'Whole shop' })
  if (auth.activeGroup && auth.isSuperAdmin) options.push({ type: 'group', id: auth.activeGroup.id, label: 'All shops' })
  return options
})
const activeScope = computed(() => scopeOptions.value.find((option) => option.type === selectedScope.value) ?? scopeOptions.value[0])
const averageTicket = computed(() =>
  report.value?.sales.orders_count ? Math.round(report.value.sales.revenue_centavos / report.value.sales.orders_count) : 0,
)
const topProductMax = computed(() => Math.max(...(report.value?.popular_products.map((item) => Number(item.quantity)) ?? [1]), 1))
const topOptionMax = computed(() => Math.max(...(report.value?.popular_options.map((item) => Number(item.quantity)) ?? [1]), 1))

function printReport() {
  window.print()
}

async function load() {
  if (!activeScope.value) return
  loading.value = true
  error.value = null
  try {
    report.value = await getReports(activeScope.value.type, activeScope.value.id, from.value, to.value)
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : String(loadError)
    report.value = null
  } finally {
    loading.value = false
  }
}

watch([from, to, selectedScope, () => auth.activeBranchId], () => void load())
onMounted(() => void load())
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'No branch' }}</p>
        <h1>Reports</h1>
        <p class="subtle">A complete operating view for the period you choose.</p>
      </div>
      <div class="heading-actions no-print">
        <select v-model="selectedScope" class="compact-select" aria-label="Report scope">
          <option v-for="option in scopeOptions" :key="option.type" :value="option.type">{{ option.label }}</option>
        </select>
        <button type="button" class="secondary small" :disabled="!report" @click="printReport">Print</button>
      </div>
    </div>

    <div class="panel filter-bar no-print">
      <label><span>From</span><input v-model="from" type="date" /></label>
      <label><span>To</span><input v-model="to" type="date" /></label>
      <button type="button" class="secondary" :disabled="loading" @click="load">{{ loading ? 'Loading…' : 'Run report' }}</button>
    </div>

    <div v-if="error" class="callout danger">{{ error }}</div>
    <div v-if="report?.profit.is_estimated" class="callout warning">
      Some sales use estimated costs because recipes were incomplete. Profit is a best estimate until those recipes are finished.
    </div>
    <div v-if="loading && !report" class="panel loading-panel">Building report…</div>
    <div v-else-if="!report" class="panel empty-panel"><h2>No report yet</h2><p>Choose a date range and run the report.</p></div>
    <template v-else>
      <div class="report-meta">
        <span>{{ activeScope?.label }}</span>
        <strong>{{ formatDate(report.from_date) }} — {{ formatDate(report.to_date) }}</strong>
        <small>{{ auth.activeShop?.name }}</small>
      </div>

      <div class="metric-grid report-metrics">
        <article class="metric-card accent"><span>Net revenue</span><strong>{{ formatPeso(report.sales.revenue_centavos) }}</strong><small>{{ report.sales.orders_count }} orders · avg {{ formatPeso(averageTicket) }}</small></article>
        <article class="metric-card"><span>Net profit</span><strong>{{ formatPeso(report.profit.net_profit_centavos) }}</strong><small>After cost and expenses</small></article>
        <article class="metric-card"><span>Food cost</span><strong>{{ formatPercentFromBasisPoints(report.profit.food_cost_bps) }}</strong><small>{{ formatPeso(report.profit.cogs_centavos) }} of revenue</small></article>
        <article class="metric-card"><span>Cash variance</span><strong>{{ formatPeso(report.cash.over_short_centavos) }}</strong><small>{{ report.cash.shifts_count }} shifts · {{ formatPeso(report.cash.cash_refunds_centavos) }} cash refunds</small></article>
      </div>

      <div class="report-grid">
        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Sales</p><h2>How money came in</h2></div></div>
          <div class="key-values">
            <div><span>Gross sales</span><b>{{ formatPeso(report.sales.gross_sales_centavos) }}</b></div>
            <div><span>Refunds</span><b>{{ formatPeso(report.sales.refunds_centavos) }}</b></div>
            <div><span>Discounts</span><b>{{ formatPeso(report.sales.discounts_centavos) }}</b></div>
            <div><span>Cash net</span><b>{{ formatPeso(report.sales.cash_net_centavos) }}</b></div>
            <div><span>GCash</span><b>{{ formatPeso(report.sales.gcash_centavos) }}</b></div>
          </div>
        </article>

        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Profit</p><h2>What was left</h2></div></div>
          <div class="key-values">
            <div><span>Gross profit</span><b>{{ formatPeso(report.profit.gross_profit_centavos) }}</b></div>
            <div><span>COGS</span><b>{{ formatPeso(report.profit.cogs_centavos) }}</b></div>
            <div><span>Operating expenses</span><b>{{ formatPeso(report.profit.expenses_centavos) }}</b></div>
            <div class="grand-total"><span>Net profit</span><b>{{ formatPeso(report.profit.net_profit_centavos) }}</b></div>
          </div>
        </article>

        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Cash</p><h2>Drawer reconciliation</h2></div></div>
          <div class="key-values">
            <div><span>Expected cash</span><b>{{ formatPeso(report.cash.expected_cash_centavos) }}</b></div>
            <div><span>Counted cash</span><b>{{ formatPeso(report.cash.counted_cash_centavos) }}</b></div>
            <div><span>Payouts</span><b>{{ formatPeso(report.cash.payouts_centavos) }}</b></div>
            <div><span>Safe drops</span><b>{{ formatPeso(report.cash.safe_drops_centavos) }}</b></div>
            <div class="grand-total"><span>Over / short</span><b :class="report.cash.over_short_centavos < 0 ? 'negative-text' : 'positive-text'">{{ formatPeso(report.cash.over_short_centavos) }}</b></div>
          </div>
        </article>

        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Production</p><h2>Batch yield</h2></div></div>
          <div class="key-values">
            <div><span>Batches</span><b>{{ report.production.batches_count }}</b></div>
            <div><span>Actual yield</span><b>{{ formatQuantity(report.production.actual_yield) }}</b></div>
            <div><span>Expected yield</span><b>{{ formatQuantity(report.production.expected_yield) }}</b></div>
            <div><span>Waste</span><b>{{ formatQuantity(report.production.waste_quantity) }}</b></div>
            <div><span>Production cost</span><b>{{ formatPeso(report.production.total_cost_centavos) }}</b></div>
          </div>
        </article>
      </div>

      <div class="report-grid lower">
        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Menu</p><h2>Popular products</h2></div></div>
          <div v-if="report.popular_products.length" class="rank-list">
            <div v-for="item in report.popular_products" :key="item.product_name" class="rank-row">
              <div><strong>{{ item.product_name }}</strong><span>{{ item.quantity }} sold</span></div>
              <div class="rank-bar"><i :style="{ width: `${(Number(item.quantity) / topProductMax) * 100}%` }"></i></div>
              <b>{{ formatPeso(Number(item.sales_centavos)) }}</b>
            </div>
          </div>
          <p v-else class="empty-state">No product sales in this period.</p>
        </article>

        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Flavors</p><h2>Popular options</h2></div></div>
          <div v-if="report.popular_options.length" class="rank-list">
            <div v-for="item in report.popular_options" :key="item.option_name" class="rank-row">
              <div><strong>{{ item.option_name }}</strong><span>{{ item.quantity }} selected</span></div>
              <div class="rank-bar gold"><i :style="{ width: `${(Number(item.quantity) / topOptionMax) * 100}%` }"></i></div>
            </div>
          </div>
          <p v-else class="empty-state">No option sales in this period.</p>
        </article>

        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Team</p><h2>Cashier performance</h2></div></div>
          <div v-if="report.cashiers.length" class="key-values">
            <div v-for="cashier in report.cashiers" :key="cashier.cashier_name ?? 'unknown'">
              <span>{{ cashier.cashier_name ?? 'Unknown' }} · {{ cashier.orders_count }} orders</span>
              <b>{{ formatPeso(Number(cashier.sales_centavos)) }}</b>
            </div>
          </div>
          <p v-else class="empty-state">No cashier sales in this period.</p>
        </article>

        <article class="panel">
          <div class="panel-title"><div><p class="eyebrow">Controls</p><h2>Corrections &amp; stock</h2></div></div>
          <div class="key-values">
            <div><span>Corrections requested</span><b>{{ report.corrections.requested_count }}</b></div>
            <div><span>Approved</span><b>{{ report.corrections.approved_count }}</b></div>
            <div><span>Refunded</span><b>{{ formatPeso(report.corrections.refunded_centavos) }}</b></div>
            <div><span>Inventory value</span><b>{{ formatPeso(report.inventory.value_centavos) }}</b></div>
            <div><span>Low stock items</span><b>{{ report.inventory.low_stock_count }}</b></div>
          </div>
        </article>
      </div>
    </template>
  </section>
</template>
