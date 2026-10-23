<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { useUiStore } from '../stores/ui'

const auth = useAuthStore()
const ui = useUiStore()
const route = useRoute()

const nav = computed(() => {
  const items = [
    { name: 'dashboard', label: 'Overview' },
    { name: 'pos', label: 'Cashier' },
    { name: 'sales', label: 'Sales' },
    { name: 'inventory', label: 'Inventory' },
  ]
  if (auth.canViewReports) items.push({ name: 'reports', label: 'Reports' })
  return items
})

function changeShop(event: Event) {
  const value = (event.target as HTMLSelectElement).value
  auth.setShop(value)
}

function changeBranch(event: Event) {
  const value = (event.target as HTMLSelectElement).value
  auth.setBranch(value)
}
</script>

<template>
  <header class="app-header">
    <RouterLink class="brand" :to="{ name: 'dashboard' }" aria-label="Benta overview">
      <div class="brand-mark">B</div>
      <div>
        <strong>Benta</strong>
        <span>Business control</span>
      </div>
    </RouterLink>

    <nav class="desktop-nav" aria-label="Primary navigation">
      <RouterLink
        v-for="item in nav"
        :key="item.name"
        :to="{ name: item.name }"
        :class="{ active: route.name === item.name || (item.name === 'sales' && route.name === 'order') }"
      >
        {{ item.label }}
      </RouterLink>
    </nav>

    <div class="context-controls">
      <label v-if="auth.shops.length > 1" class="header-select shop-select">
        <span class="sr-only">Active shop</span>
        <select :value="auth.activeShopId ?? ''" @change="changeShop">
          <option v-for="shop in auth.shops" :key="shop.id" :value="shop.id">{{ shop.name }}</option>
        </select>
      </label>
      <label v-if="auth.branchesForShop.length > 1" class="header-select">
        <span class="sr-only">Active branch</span>
        <select :value="auth.activeBranchId ?? ''" @change="changeBranch">
          <option v-for="branch in auth.branchesForShop" :key="branch.id" :value="branch.id">
            {{ branch.name }}
          </option>
        </select>
      </label>
      <span v-else-if="auth.activeBranch" class="branch-chip">{{ auth.activeBranch.name }}</span>
      <span v-else-if="auth.activeShop" class="branch-chip muted">No branches</span>
      <span class="status" :class="ui.online ? 'online' : 'offline'">
        <i></i>{{ ui.online ? 'Online' : 'Offline' }}
      </span>
      <RouterLink class="user-chip" :to="{ name: 'more' }" :title="auth.displayName">
        <span>{{ auth.displayName.slice(0, 1).toUpperCase() }}</span>
        <em>{{ auth.role?.replace('_', ' ') ?? 'no role' }}</em>
      </RouterLink>
    </div>
  </header>
</template>
