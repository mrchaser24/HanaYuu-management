<script setup lang="ts">
import { useBusinessStore } from '../stores/business'

defineProps<{ active: string }>()
defineEmits<{ change: [view: string] }>()

const store = useBusinessStore()
</script>

<template>
  <header class="app-header">
    <div class="brand">
      <div class="brand-mark">B</div>
      <div>
        <strong>Benta</strong>
        <span>Business control</span>
      </div>
    </div>

    <nav class="desktop-nav" aria-label="Primary navigation">
      <button :class="{ active: active === 'dashboard' }" @click="$emit('change', 'dashboard')">Overview</button>
      <button :class="{ active: active === 'pos' }" @click="$emit('change', 'pos')">Cashier</button>
      <button :class="{ active: active === 'inventory' }" @click="$emit('change', 'inventory')">Inventory</button>
    </nav>
    <div class="context-controls">
      <label>
        <span class="sr-only">Active branch</span>
        <select :value="store.branch" @change="store.setBranch(($event.target as HTMLSelectElement).value)">
          <option>Downtown Branch</option>
          <option>Market Branch</option>
        </select>
      </label>
      <label>
        <span class="sr-only">Role preview</span>
        <select :value="store.role" @change="store.setRole(($event.target as HTMLSelectElement).value as 'super_admin' | 'owner' | 'staff')">
          <option value="staff">Staff</option>
          <option value="owner">Owner</option>
          <option value="super_admin">Super admin</option>
        </select>
      </label>
      <span class="status" :class="store.isOnline ? 'online' : 'offline'">
        <i></i>{{ store.isOnline ? 'Online' : 'Offline' }}
      </span>
    </div>
  </header>
</template>
