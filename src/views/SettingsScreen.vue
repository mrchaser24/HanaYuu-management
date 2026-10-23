<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import VaultDialog from '../components/VaultDialog.vue'
import { getReports } from '../lib/api'
import { daysAgoManila, formatDate, manilaDate } from '../lib/datetime'
import { formatPeso, formatPercentFromBasisPoints } from '../lib/money'
import { useAuthStore } from '../stores/auth'
import { useOfflineStore } from '../stores/offline'
import { useUiStore } from '../stores/ui'
import type { ReportResponse, ScopeType } from '../lib/types'

import AdminScreen from './AdminScreen.vue'

type SettingsTab = 'account' | 'offline' | 'reports' | 'admin'

const auth = useAuthStore()
const offline = useOfflineStore()
const ui = useUiStore()
const router = useRouter()

const activeTab = ref<SettingsTab>('account')
const showVault = ref(false)
const report = ref<ReportResponse | null>(null)
const reportFrom = ref(daysAgoManila(29))
const reportTo = ref(manilaDate())
const reportScope = ref<ScopeType>('branch')
const reportLoading = ref(false)
const reportError = ref<string | null>(null)

const scopeOptions = computed(() => {
  const options: Array<{ type: ScopeType; id: string; label: string }> = []
  if (auth.activeBranch) options.push({ type: 'branch', id: auth.activeBranch.id, label: 'This branch' })
  if (auth.activeShop && auth.canManageShop) options.push({ type: 'shop', id: auth.activeShop.id, label: 'Whole shop' })
  if (auth.activeGroup && auth.isSuperAdmin) options.push({ type: 'group', id: auth.activeGroup.id, label: 'All shops' })
  return options
})
const activeScope = computed(() => scopeOptions.value.find((o) => o.type === reportScope.value) ?? scopeOptions.value[0])
const avgTicket = computed(() => report.value?.sales.orders_count ? Math.round(report.value.sales.revenue_centavos / report.value.sales.orders_count) : 0)

const tabs = computed(() => {
  const items: Array<{ id: SettingsTab; label: string }> = [{ id: 'account', label: 'Account' }]
  items.push({ id: 'offline', label: 'Offline' })
  if (auth.isOwner) items.push({ id: 'reports', label: 'Reports' })
  if (auth.isOwner) items.push({ id: 'admin', label: 'Admin' })
  return items
})

async function loadReport() {
  if (!activeScope.value) return
  reportLoading.value = true
  reportError.value = null
  try {
    report.value = await getReports(activeScope.value.type, activeScope.value.id, reportFrom.value, reportTo.value)
  } catch (err) {
    reportError.value = err instanceof Error ? err.message : String(err)
  } finally {
    reportLoading.value = false
  }
}

async function handleSignOut() {
  if (offline.pendingCount && !window.confirm('You have unsynced sales. Sign out anyway?')) return
  await auth.signOut()
  await router.push({ name: 'login' })
}

watch(activeTab, (tab) => {
  if (tab === 'reports' && !report.value) void loadReport()
})
</script>

<template>
  <section>
    <div class="section-heading">
      <div>
        <p class="eyebrow">{{ auth.activeBranch?.name ?? 'Business' }}</p>
        <h1>Settings</h1>
      </div>
    </div>

    <div class="tabs admin-tabs">
      <button v-for="tab in tabs" :key="tab.id" type="button" :class="{ active: activeTab === tab.id }" @click="activeTab = tab.id">{{ tab.label }}</button>
    </div>

    <!-- Account -->
    <div v-if="activeTab === 'account'" class="admin-grid">
      <article class="panel">
        <div class="panel-title"><div><p class="eyebrow">Profile</p><h2>Your account</h2></div></div>
        <div class="key-values">
          <div><span>Name</span><b>{{ auth.displayName }}</b></div>
          <div><span>Email</span><b>{{ auth.email }}</b></div>
          <div><span>Role</span><b>{{ auth.role?.replace('_', ' ') ?? 'No role' }}</b></div>
          <div><span>Shop</span><b>{{ auth.activeShop?.name ?? 'None' }}</b></div>
          <div><span>Branch</span><b>{{ auth.activeBranch?.name ?? 'None' }}</b></div>
        </div>
        <div style="margin-top:16px">
          <button type="button" class="secondary" @click="handleSignOut">Sign out</button>
        </div>
      </article>
      <article class="panel">
        <div class="panel-title"><div><p class="eyebrow">Connection</p><h2>Status</h2></div></div>
        <div class="key-values">
          <div><span>Connection</span><b>{{ ui.online ? 'Online' : 'Offline' }}</b></div>
          <div><span>Pending offline sales</span><b>{{ offline.pendingCount }}</b></div>
          <div><span>Device registered</span><b>{{ offline.currentDevice ? 'Yes' : 'No' }}</b></div>
        </div>
      </article>
    </div>

    <!-- Offline -->
    <div v-else-if="activeTab === 'offline'" class="admin-grid">
      <article class="panel">
        <div class="panel-title"><div><p class="eyebrow">Encryption</p><h2>Offline vault</h2></div></div>
        <p class="subtle">Set a PIN to encrypt offline sales on this device.</p>
        <div v-if="offline.unlocked" class="callout success" style="margin-top:12px">
          Vault is unlocked. Offline sales are encrypted.
        </div>
        <div v-else style="margin-top:12px">
          <button type="button" class="primary" @click="showVault = true">
            {{ offline.vaultExists ? 'Unlock vault' : 'Create PIN' }}
          </button>
        </div>
        <div class="key-values" style="margin-top:14px">
          <div><span>Saved sales</span><b>{{ offline.pendingCount }}</b></div>
          <div><span>Device</span><b>{{ offline.currentDevice ? 'Registered' : 'Not registered' }}</b></div>
        </div>
      </article>
      <article v-if="!offline.currentDevice && auth.activeBranch" class="panel">
        <div class="panel-title"><div><p class="eyebrow">Setup</p><h2>Register device</h2></div></div>
        <p class="subtle">Register this browser for {{ auth.activeBranch.name }} to enable offline sales.</p>
        <button type="button" class="primary" style="margin-top:12px" @click="offline.ensureDevice(auth.activeBranchId!)">Register now</button>
      </article>
    </div>

    <!-- Reports -->
    <div v-else-if="activeTab === 'reports'">
      <div class="heading-actions" style="margin-bottom:16px">
        <select v-model="reportScope" class="compact-select" aria-label="Report scope">
          <option v-for="opt in scopeOptions" :key="opt.type" :value="opt.type">{{ opt.label }}</option>
        </select>
        <input v-model="reportFrom" type="date" class="compact-select" />
        <input v-model="reportTo" type="date" class="compact-select" />
        <button type="button" class="primary small" :disabled="reportLoading" @click="loadReport">{{ reportLoading ? 'Loading…' : 'Load' }}</button>
      </div>
      <div v-if="reportError" class="callout danger">{{ reportError }}</div>
      <div v-else-if="!report && !reportLoading" class="panel empty-state">Select a date range and tap Load.</div>
      <div v-else-if="reportLoading && !report" class="panel">Loading report…</div>
      <template v-else-if="report">
        <div v-if="report.profit.is_estimated" class="callout warning">Some products have no recipe. Profit includes estimated costs.</div>
        <div class="metric-grid" style="margin-bottom:16px">
          <article class="metric-card accent"><span>Net revenue</span><strong>{{ formatPeso(report.sales.revenue_centavos) }}</strong><small>{{ report.sales.orders_count }} orders · avg {{ formatPeso(avgTicket) }}</small></article>
          <article class="metric-card"><span>Net profit</span><strong>{{ formatPeso(report.profit.net_profit_centavos) }}</strong><small>After cost and expenses</small></article>
          <article class="metric-card"><span>Food cost</span><strong>{{ formatPercentFromBasisPoints(report.profit.food_cost_bps) }}</strong><small>{{ formatPeso(report.profit.cogs_centavos) }} of revenue</small></article>
          <article class="metric-card"><span>Expenses</span><strong>{{ formatPeso(report.profit.expenses_centavos) }}</strong><small>Operating costs</small></article>
        </div>
        <div class="admin-grid">
          <article class="panel">
            <div class="panel-title"><div><p class="eyebrow">Profit & Loss</p><h2>{{ formatDate(reportFrom) }} — {{ formatDate(reportTo) }}</h2></div></div>
            <div class="key-values">
              <div><span>Gross sales</span><b>{{ formatPeso(report.sales.gross_sales_centavos) }}</b></div>
              <div><span>Discounts</span><b>-{{ formatPeso(report.sales.discounts_centavos) }}</b></div>
              <div><span>Refunds</span><b>-{{ formatPeso(report.sales.refunds_centavos) }}</b></div>
              <div><span>Net revenue</span><b>{{ formatPeso(report.sales.revenue_centavos) }}</b></div>
              <div><span>COGS (food cost)</span><b>-{{ formatPeso(report.profit.cogs_centavos) }}</b></div>
              <div><span>Gross profit</span><b>{{ formatPeso(report.profit.gross_profit_centavos) }}</b></div>
              <div><span>Operating expenses</span><b>-{{ formatPeso(report.profit.expenses_centavos) }}</b></div>
              <div class="grand-total"><span>Net profit</span><b>{{ formatPeso(report.profit.net_profit_centavos) }}</b></div>
            </div>
          </article>
          <div>
            <article class="panel" style="margin-bottom:14px">
              <div class="panel-title"><div><p class="eyebrow">Popularity</p><h2>Top products</h2></div></div>
              <ol v-if="report.popular_products.length" class="popular-list">
                <li v-for="(item, i) in report.popular_products.slice(0, 8)" :key="item.product_name"><b>{{ i + 1 }}</b><span>{{ item.product_name }}</span><strong>{{ item.quantity }} sold</strong></li>
              </ol>
              <div v-else class="empty-state">No product data for this period.</div>
            </article>
            <article class="panel">
              <div class="panel-title"><div><p class="eyebrow">Flavors</p><h2>Top options</h2></div></div>
              <ol v-if="report.popular_options.length" class="popular-list">
                <li v-for="(item, i) in report.popular_options.slice(0, 8)" :key="item.option_name"><b>{{ i + 1 }}</b><span>{{ item.option_name }}</span><strong>{{ item.quantity }} picked</strong></li>
              </ol>
              <div v-else class="empty-state">No flavor data for this period.</div>
            </article>
          </div>
        </div>
        <article class="panel" style="margin-top:14px">
          <div class="panel-title"><div><p class="eyebrow">Cash &amp; payments</p><h2>Payment breakdown</h2></div></div>
          <div class="key-values">
            <div><span>Cash net</span><b>{{ formatPeso(report.sales.cash_net_centavos) }}</b></div>
            <div><span>GCash</span><b>{{ formatPeso(report.sales.gcash_centavos) }}</b></div>
            <div><span>Cash refunds</span><b>-{{ formatPeso(report.cash.over_short_centavos) }}</b></div>
            <div><span>Cash payouts</span><b>-{{ formatPeso(report.cash.payouts_centavos) }}</b></div>
            <div><span>Safe drops</span><b>-{{ formatPeso(report.cash.safe_drops_centavos) }}</b></div>
          </div>
        </article>
      </template>
    </div>

    <!-- Admin (reuses existing full admin screen) -->
    <AdminScreen v-else-if="activeTab === 'admin'" />

    <VaultDialog v-if="showVault" @unlocked="showVault = false; ui.success('Vault unlocked')" @created="showVault = false; ui.success('PIN created')" @close="showVault = false" />
  </section>
</template>
