<script setup lang="ts">
import { useUiStore } from '../stores/ui'

const ui = useUiStore()
</script>

<template>
  <div class="toast-stack" aria-live="polite">
    <article v-for="toast in ui.toasts" :key="toast.id" class="app-toast" :class="toast.tone">
      <div>
        <strong>{{ toast.title }}</strong>
        <p v-if="toast.detail">{{ toast.detail }}</p>
      </div>
      <button type="button" aria-label="Dismiss notification" @click="ui.dismiss(toast.id)">×</button>
    </article>
  </div>
</template>
