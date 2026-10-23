<script setup lang="ts">
import { useRoute } from 'vue-router'

const route = useRoute()
const items = [
  { name: 'dashboard', label: 'Overview', icon: '◌' },
  { name: 'pos', label: 'POS', icon: '⊞' },
  { name: 'sales', label: 'Sales', icon: '↗' },
  { name: 'inventory', label: 'Stock', icon: '▦' },
  { name: 'more', label: 'More', icon: '•••' },
]
</script>

<template>
  <nav class="bottom-nav" aria-label="Main navigation">
    <RouterLink
      v-for="item in items"
      :key="item.name"
      :to="{ name: item.name }"
      :class="{ active: route.name === item.name || (item.name === 'sales' && route.name === 'order') }"
    >
      <span>{{ item.icon }}</span>{{ item.label }}
    </RouterLink>
  </nav>
</template>
