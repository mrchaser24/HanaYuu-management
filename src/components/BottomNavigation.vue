<script setup lang="ts">
defineProps<{ active: string }>()
defineEmits<{ change: [view: string] }>()

const items = [
  { id: 'dashboard', label: 'Overview', icon: '◌' },
  { id: 'pos', label: 'POS', icon: '⊞' },
  { id: 'sales', label: 'Sales', icon: '↗' },
  { id: 'inventory', label: 'Stock', icon: '▦' },
  { id: 'more', label: 'More', icon: '•••' },
]
</script>

<template>
  <nav class="bottom-nav" aria-label="Main navigation">
    <button v-for="item in items" :key="item.id" :class="{ active: active === item.id }" @click="$emit('change', item.id)">
      <span>{{ item.icon }}</span>{{ item.label }}
    </button>
  </nav>
</template>
