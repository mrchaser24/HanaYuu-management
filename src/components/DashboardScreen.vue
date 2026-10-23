<script setup lang="ts">
import { computed } from 'vue'
import { formatPeso } from '../lib/money'
import { useBusinessStore } from '../stores/business'

const store = useBusinessStore()
const metrics = computed(() => store.metrics)
const popular = computed(() => {
  const counts = new Map<string, number>()
  for (const sale of store.sales) for (const item of sale.items) for (const flavor of item.flavors) counts.set(flavor, (counts.get(flavor) ?? 0) + item.quantity)
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3)
})
</script>

<template>
  <section class="dashboard">
    <div class="section-heading"><div><p class="eyebrow">{{ store.branch }} · Today</p><h1>Good morning, Alex</h1><p class="subtle">Here is how your branch is doing today.</p></div><span class="pill" :class="store.isOnline ? 'success' : 'warning'">{{ store.isOnline ? 'Synced' : `${metrics.pendingSyncCount} pending` }}</span></div>

    <div class="metric-grid">
      <article class="metric-card accent"><span>Today’s sales</span><strong>{{ formatPeso(metrics.todaySalesCentavos) }}</strong><small>Completed transactions</small></article>
      <article class="metric-card"><span>Today’s profit</span><strong>{{ formatPeso(metrics.todayProfitCentavos) }}</strong><small>Estimated after food cost</small></article>
      <article class="metric-card"><span>Inventory value</span><strong>{{ formatPeso(metrics.inventoryValueCentavos) }}</strong><small>Raw & prepared stock</small></article>
      <article class="metric-card"><span>Low-stock items</span><strong>3</strong><small>Check inventory soon</small></article>
    </div>

    <div class="dashboard-columns">
      <article class="panel chart-panel"><div class="panel-title"><div><p class="eyebrow">Sales trend</p><h2>This week</h2></div><span>₱</span></div><div class="bars" aria-label="Illustrative weekly sales chart"><i style="height:42%"></i><i style="height:64%"></i><i style="height:54%"></i><i style="height:82%"></i><i style="height:70%"></i><i style="height:95%"></i><i style="height:58%"></i></div><div class="chart-labels"><span>M</span><span>T</span><span>W</span><span>T</span><span>F</span><span>S</span><span>S</span></div></article>
      <article class="panel"><div class="panel-title"><div><p class="eyebrow">Popular today</p><h2>Top flavors</h2></div><span>🍗</span></div><ol v-if="popular.length" class="popular-list"><li v-for="([flavor, count], index) in popular" :key="flavor"><b>{{ index + 1 }}</b><span>{{ flavor }}</span><strong>{{ count }} orders</strong></li></ol><div v-else class="empty-state">Complete a sale to see your popular flavors.</div></article>
    </div>

    <article class="panel activity-panel"><div class="panel-title"><div><p class="eyebrow">Live activity</p><h2>Recent sales</h2></div></div><div v-if="store.sales.length" class="activity-list"><div v-for="sale in store.sales.slice(0, 5)" :key="sale.id" class="activity-item"><div class="activity-icon">{{ sale.paymentMethod === 'cash' ? '₱' : 'G' }}</div><div><strong>{{ sale.orderNumber }}</strong><small>{{ sale.cashierName }} · {{ new Date(sale.createdAt).toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' }) }}</small></div><div class="activity-amount"><strong>{{ formatPeso(sale.totalCentavos) }}</strong><small :class="sale.status">{{ sale.status.replace('_', ' ') }}</small></div></div></div><div v-else class="empty-state">No sales yet today. Start a sale from the POS.</div></article>
  </section>
</template>
