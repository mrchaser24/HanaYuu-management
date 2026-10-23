<script setup lang="ts">
import { useRoute } from 'vue-router'

const route = useRoute()
const items = [
  { name: 'home', label: 'Home', icon: '◌' },
  { name: 'pos', label: 'Sell', icon: '⊞' },
  { name: 'record', label: 'Record', icon: '+' },
  { name: 'history', label: 'History', icon: '↗' },
  { name: 'settings', label: 'Settings', icon: '⚙' },
]
</script>

<template>
  <nav class="bottom-nav" aria-label="Main navigation">
    <RouterLink
      v-for="item in items"
      :key="item.name"
      :to="{ name: item.name }"
      :class="{ active: route.name === item.name || (item.name === 'history' && route.name === 'order') }"
    >
      <span>{{ item.icon }}</span>{{ item.label }}
    </RouterLink>
  </nav>
</template>
