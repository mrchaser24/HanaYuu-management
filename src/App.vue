<script setup lang="ts">
import { ref } from 'vue'
import AppHeader from './components/AppHeader.vue'
import BottomNavigation from './components/BottomNavigation.vue'
import DashboardScreen from './components/DashboardScreen.vue'
import PosScreen from './components/PosScreen.vue'
import { useBusinessStore } from './stores/business'

const activeView = ref('dashboard')
const store = useBusinessStore()
</script>

<template>
  <div class="app-shell">
    <AppHeader :active="activeView" @change="activeView = $event" />
    <main class="app-main">
      <DashboardScreen v-if="activeView === 'dashboard'" />
      <PosScreen v-else-if="activeView === 'pos'" />
      <section v-else class="coming-soon panel"><p class="eyebrow">{{ activeView }}</p><h1>Ready for your business</h1><p>This area will use the same secure branch data and permission controls once Supabase is connected.</p><button class="primary" @click="activeView = 'pos'">Open cashier</button></section>
    </main>
    <BottomNavigation :active="activeView" @change="activeView = $event" />
    <aside v-if="store.pendingSyncCount" class="sync-banner">{{ store.pendingSyncCount }} action{{ store.pendingSyncCount > 1 ? 's' : '' }} saved locally and waiting to sync.</aside>
  </div>
</template>
